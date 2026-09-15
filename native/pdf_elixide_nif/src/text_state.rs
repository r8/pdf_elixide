// Compare upstream's unstacked text state with q/Q restoration at each show.
// Re-established state must converge, so ordinary q/Q blocks remain accepted.

use pdf_oxide::content::{parse_content_stream, Matrix, Operator};

// The text-state parameters, which ISO 32000-1 Table 52 makes part of the
// graphics state — so `q` saves these and `Q` restores them. `Tr` is absent
// because upstream tracks it nowhere and so cannot disagree about it.
#[derive(Clone, Default, PartialEq)]
struct Params {
    font: String,
    size: f32,
    char_space: f32,
    word_space: f32,
    horizontal_scaling: f32,
    leading: f32,
    rise: f32,
}

// One reading of the page.
#[derive(Clone)]
struct Reading {
    params: Params,
    // Q does not restore matrices. A line move can retain a leading divergence
    // even after TL brings the parameters back into agreement.
    line_matrix: Matrix,
}

impl Default for Reading {
    fn default() -> Self {
        Reading {
            params: Params {
                // Match upstream's TextState default.
                horizontal_scaling: 1.0,
                ..Params::default()
            },
            line_matrix: Matrix::identity(),
        }
    }
}

impl Reading {
    // Compare glyph_box inputs. Leading matters only through line_matrix;
    // comparing it directly would reject discarded leading that never moved text.
    fn measurement(&self) -> (&str, f32, f32, f32, f32, f32, Matrix) {
        (
            &self.params.font,
            self.params.size,
            self.params.char_space,
            self.params.word_space,
            self.params.horizontal_scaling,
            self.params.rise,
            self.line_matrix,
        )
    }

    fn translate(&mut self, tx: f32, ty: f32) {
        self.line_matrix = Matrix {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            e: tx,
            f: ty,
        }
        .multiply(&self.line_matrix);
    }

    // `T*`, and the line move `'` and `"` perform before showing. Each reading
    // moves by *its own* leading, which is where a divergence is created.
    fn next_line(&mut self) {
        self.translate(0.0, -self.params.leading);
    }
}

// `true` when the page shows text the engine would measure with a restored
// state. Unparseable bytes answer `false` so upstream's own parse error stays
// the one the caller sees.
pub fn measures_restored_text_state(content: &[u8]) -> bool {
    let Ok(ops) = parse_content_stream(content) else {
        return false;
    };

    // `flat` is what the engine's unstacked state will hold; `correct` is what
    // the spec says a `Q` restores.
    let mut flat = Reading::default();
    let mut correct = flat.clone();
    let mut saved: Vec<Params> = Vec::new();

    for op in &ops {
        match op {
            Operator::SaveState => saved.push(correct.params.clone()),
            Operator::RestoreState => {
                // `GraphicsStateStack::restore` keeps its base entry, so a `Q`
                // that pops nothing is a no-op there and must be one here. The
                // matrix is left alone in both readings, as upstream leaves it.
                if let Some(outer) = saved.pop() {
                    correct.params = outer;
                }
            }
            Operator::Tf { font, size } => {
                for state in [&mut flat, &mut correct] {
                    state.params.font.clone_from(font);
                    state.params.size = *size;
                }
            }
            Operator::Tc { char_space } => {
                for state in [&mut flat, &mut correct] {
                    state.params.char_space = *char_space;
                }
            }
            Operator::Tw { word_space } => {
                for state in [&mut flat, &mut correct] {
                    state.params.word_space = *word_space;
                }
            }
            Operator::Tz { scale } => {
                for state in [&mut flat, &mut correct] {
                    state.params.horizontal_scaling = *scale / 100.0;
                }
            }
            Operator::TL { leading } => {
                for state in [&mut flat, &mut correct] {
                    state.params.leading = *leading;
                }
            }
            Operator::Ts { rise } => {
                for state in [&mut flat, &mut correct] {
                    state.params.rise = *rise;
                }
            }
            // BT and Tm converge the matrices, ending any position divergence.
            Operator::BeginText => {
                for state in [&mut flat, &mut correct] {
                    state.line_matrix = Matrix::identity();
                }
            }
            Operator::Tm { a, b, c, d, e, f } => {
                for state in [&mut flat, &mut correct] {
                    state.line_matrix = Matrix {
                        a: *a,
                        b: *b,
                        c: *c,
                        d: *d,
                        e: *e,
                        f: *f,
                    };
                }
            }
            Operator::Td { tx, ty } => {
                for state in [&mut flat, &mut correct] {
                    state.translate(*tx, *ty);
                }
            }
            // `TD` sets the leading as well as moving, which is the whole of
            // its difference from `Td` and easy to miss.
            Operator::TD { tx, ty } => {
                for state in [&mut flat, &mut correct] {
                    state.params.leading = -*ty;
                    state.translate(*tx, *ty);
                }
            }
            Operator::TStar => {
                for state in [&mut flat, &mut correct] {
                    state.next_line();
                }
            }
            Operator::Quote { .. } => {
                for state in [&mut flat, &mut correct] {
                    state.next_line();
                }
            }
            Operator::DoubleQuote {
                word_space,
                char_space,
                ..
            } => {
                // Upstream's order: `"` assigns its own spacing, then moves the
                // line, then shows.
                for state in [&mut flat, &mut correct] {
                    state.params.word_space = *word_space;
                    state.params.char_space = *char_space;
                    state.next_line();
                }
            }
            _ => {}
        }

        // Omitted glyph advances are equal until the first divergence, where
        // this returns; both matrices lack the same displacement.
        if shows_text(op) && flat.measurement() != correct.measurement() {
            return true;
        }
    }

    false
}

fn shows_text(op: &Operator) -> bool {
    matches!(
        op,
        Operator::Tj { .. }
            | Operator::TJ { .. }
            | Operator::Quote { .. }
            | Operator::DoubleQuote { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::measures_restored_text_state;

    #[test]
    fn a_page_that_never_saves_state_is_measurable() {
        assert!(!measures_restored_text_state(
            b"/F1 24 Tf BT 100 700 Td (Secret) Tj ET"
        ));
    }

    #[test]
    fn a_font_size_restored_before_a_show_is_not() {
        assert!(measures_restored_text_state(
            b"/F1 24 Tf q /F1 1 Tf Q BT 100 700 Td (Secret) Tj ET"
        ));
    }

    #[test]
    fn the_same_page_re_setting_the_font_before_showing_is_measurable() {
        assert!(!measures_restored_text_state(
            b"/F1 24 Tf q /F1 1 Tf Q /F1 24 Tf BT 100 700 Td (Secret) Tj ET"
        ));
    }

    #[test]
    fn a_show_inside_the_block_is_measurable() {
        // Nothing has been restored yet, so both readings agree.
        assert!(!measures_restored_text_state(
            b"/F1 24 Tf q /F1 1 Tf BT (Secret) Tj ET Q"
        ));
    }

    #[test]
    fn a_font_name_restored_before_a_show_is_not() {
        // The size agrees; only the name the widths and the composite-font gate
        // are read from has been discarded.
        assert!(measures_restored_text_state(
            b"/F1 24 Tf q /F2 24 Tf Q BT (Secret) Tj ET"
        ));
    }

    #[test]
    fn each_spacing_parameter_diverges_on_its_own() {
        for stream in [
            b"1 Tc q 9 Tc Q BT (S) Tj ET".as_slice(),
            b"1 Tw q 9 Tw Q BT (S) Tj ET".as_slice(),
            b"50 Tz q 90 Tz Q BT (S) Tj ET".as_slice(),
            b"1 Ts q 9 Ts Q BT (S) Tj ET".as_slice(),
        ] {
            assert!(
                measures_restored_text_state(stream),
                "{}",
                String::from_utf8_lossy(stream)
            );
        }
    }

    #[test]
    fn a_double_quote_supplies_its_own_spacing_but_not_its_font() {
        // `"` assigns tw and tc before showing, so a discarded spacing cannot
        // reach its measurement...
        assert!(!measures_restored_text_state(
            b"/F1 24 Tf 1 Tw q 9 Tw Q BT 2 3 (S) \" ET"
        ));

        // ...but a discarded font still does.
        assert!(measures_restored_text_state(
            b"/F1 24 Tf q /F1 1 Tf Q BT 2 3 (S) \" ET"
        ));
    }

    #[test]
    fn an_unbalanced_restore_does_not_underflow() {
        // Upstream's stack keeps its base entry, so the stray `Q` restores
        // nothing and the later block still reports its own divergence.
        assert!(!measures_restored_text_state(b"Q /F1 24 Tf BT (S) Tj ET"));
        assert!(measures_restored_text_state(
            b"Q /F1 24 Tf q /F1 1 Tf Q BT (S) Tj ET"
        ));
    }

    #[test]
    fn an_unbalanced_save_leaves_the_state_it_set() {
        assert!(!measures_restored_text_state(
            b"/F1 24 Tf q /F1 1 Tf BT (S) Tj ET"
        ));
    }

    #[test]
    fn unparseable_bytes_defer_to_upstreams_own_error() {
        assert!(!measures_restored_text_state(
            b"<<<<<< not a content stream"
        ));
    }

    #[test]
    fn a_leading_set_by_td_reaches_a_later_line_move() {
        // `TD` sets the leading as a side effect, so the restore discards it and
        // upstream's `T*` moves the line 100 down instead of 14. The parameters
        // alone would not show it: nothing here writes `TL` after the block.
        assert!(measures_restored_text_state(
            b"14 TL q 0 -100 TD Q BT 100 780 Td T* (S) Tj ET"
        ));

        // The same `TD` with no line move afterwards changes no measurement, and
        // is not refused: a discarded leading that never moves a line cannot
        // reach a glyph box.
        assert!(!measures_restored_text_state(
            b"14 TL q 0 -100 TD Q BT 100 780 Td (S) Tj ET"
        ));
    }

    #[test]
    fn a_discarded_leading_is_reported_only_where_it_moves_a_line() {
        assert!(!measures_restored_text_state(b"1 TL q 9 TL Q BT (S) Tj ET"));

        for mover in [
            b"T* (S) Tj".as_slice(),
            b"(S) '".as_slice(),
            b"2 3 (S) \"".as_slice(),
        ] {
            let mut stream = b"1 TL q 9 TL Q BT ".to_vec();
            stream.extend_from_slice(mover);
            stream.extend_from_slice(b" ET");
            assert!(
                measures_restored_text_state(&stream),
                "{}",
                String::from_utf8_lossy(&stream)
            );
        }
    }

    #[test]
    fn a_line_moved_by_a_stale_leading_stays_moved() {
        // The `TL` after the `T*` puts the parameters back in agreement, which
        // cannot undo where the line already went. Comparing parameters alone
        // accepted this page.
        assert!(measures_restored_text_state(
            b"14 TL q 100 TL Q BT 100 780 Td T* 14 TL (S) Tj ET"
        ));
    }

    #[test]
    fn a_text_object_or_an_explicit_matrix_re_establishes_the_line() {
        // `BT` and `Tm` set the matrix outright, so a divergence before one of
        // them is not reported after it.
        assert!(!measures_restored_text_state(
            b"14 TL q 100 TL Q BT 100 780 Td T* 14 TL ET BT 100 700 Td (S) Tj ET"
        ));
        assert!(!measures_restored_text_state(
            b"14 TL q 100 TL Q BT 100 780 Td T* 14 TL 1 0 0 1 100 700 Tm (S) Tj ET"
        ));
    }

    #[test]
    fn a_plain_move_never_diverges_on_its_own() {
        assert!(!measures_restored_text_state(
            b"/F1 24 Tf q 0 -100 Td Q BT 100 780 Td T* (S) Tj ET"
        ));
    }
}
