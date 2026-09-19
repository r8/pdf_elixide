use pdf_oxide::elements::{LineCap, LineJoin, PathContent, PathOperation};
use rustler::{Encoder, Env, NifMap, NifUnitEnum, Term};

use crate::{
    atoms,
    color::{color_to_nif, RgbNif},
    geometry::{finite, rect_to_nif, RectNif},
};

#[derive(NifMap, Debug)]
#[rustler(encode)]
pub struct PathNif {
    page: usize,
    bbox: RectNif,
    operations: Vec<PathOpNif>,
    stroke_color: Option<RgbNif>,
    fill_color: Option<RgbNif>,
    stroke_width: f32,
    line_cap: LineCapNif,
    line_join: LineJoinNif,
    dash_pattern: Option<(Vec<f32>, f32)>,
    layer: Option<String>,
}

#[derive(NifUnitEnum, Debug)]
pub enum LineCapNif {
    Butt,
    Round,
    Square,
}

#[derive(NifUnitEnum, Debug)]
pub enum LineJoinNif {
    Miter,
    Round,
    Bevel,
}

// A single path operation, encoded to Elixir as a flat tagged tuple
// (`{:move_to, x, y}`, `{:curve_to, c1x, c1y, c2x, c2y, ex, ey}`, ...) or, for
// `ClosePath`, the bare atom `:close_path`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PathOpNif {
    MoveTo(f32, f32),
    LineTo(f32, f32),
    CurveTo(f32, f32, f32, f32, f32, f32),
    Rectangle(f32, f32, f32, f32),
    ClosePath,
}

impl Encoder for PathOpNif {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match *self {
            PathOpNif::MoveTo(x, y) => (atoms::move_to(), x, y).encode(env),
            PathOpNif::LineTo(x, y) => (atoms::line_to(), x, y).encode(env),
            PathOpNif::CurveTo(c1x, c1y, c2x, c2y, ex, ey) => {
                (atoms::curve_to(), c1x, c1y, c2x, c2y, ex, ey).encode(env)
            }
            PathOpNif::Rectangle(x, y, w, h) => (atoms::rectangle(), x, y, w, h).encode(env),
            PathOpNif::ClosePath => atoms::close_path().encode(env),
        }
    }
}

impl From<PathOperation> for PathOpNif {
    fn from(op: PathOperation) -> Self {
        match op {
            PathOperation::MoveTo(x, y) => PathOpNif::MoveTo(finite(x), finite(y)),
            PathOperation::LineTo(x, y) => PathOpNif::LineTo(finite(x), finite(y)),
            PathOperation::CurveTo(c1x, c1y, c2x, c2y, ex, ey) => PathOpNif::CurveTo(
                finite(c1x),
                finite(c1y),
                finite(c2x),
                finite(c2y),
                finite(ex),
                finite(ey),
            ),
            PathOperation::Rectangle(x, y, w, h) => {
                PathOpNif::Rectangle(finite(x), finite(y), finite(w), finite(h))
            }
            PathOperation::ClosePath => PathOpNif::ClosePath,
        }
    }
}

impl From<LineCap> for LineCapNif {
    fn from(cap: LineCap) -> Self {
        match cap {
            LineCap::Butt => LineCapNif::Butt,
            LineCap::Round => LineCapNif::Round,
            LineCap::Square => LineCapNif::Square,
        }
    }
}

impl From<LineJoin> for LineJoinNif {
    fn from(join: LineJoin) -> Self {
        match join {
            LineJoin::Miter => LineJoinNif::Miter,
            LineJoin::Round => LineJoinNif::Round,
            LineJoin::Bevel => LineJoinNif::Bevel,
        }
    }
}

pub fn path_to_nif(path: PathContent, page: usize) -> PathNif {
    PathNif {
        page,
        bbox: rect_to_nif(path.bbox),
        operations: path.operations.into_iter().map(PathOpNif::from).collect(),
        stroke_color: path.stroke_color.map(color_to_nif),
        fill_color: path.fill_color.map(color_to_nif),
        stroke_width: finite(path.stroke_width),
        line_cap: path.line_cap.into(),
        line_join: path.line_join.into(),
        dash_pattern: path
            .dash_pattern
            .map(|(dashes, phase)| (dashes.into_iter().map(finite).collect(), finite(phase))),
        layer: path.layer,
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{geometry::Rect, layout::Color};

    use super::*;

    #[test]
    fn every_path_float_crosses_finite() {
        let (inf, ninf, nan) = (f32::INFINITY, f32::NEG_INFINITY, f32::NAN);
        let path = PathContent {
            bbox: Rect {
                x: f32::INFINITY,
                y: f32::NEG_INFINITY,
                width: f32::NAN,
                height: f32::INFINITY,
            },
            operations: vec![
                PathOperation::MoveTo(inf, ninf),
                PathOperation::LineTo(nan, inf),
                PathOperation::CurveTo(inf, ninf, nan, inf, ninf, nan),
                PathOperation::Rectangle(inf, ninf, nan, inf),
                PathOperation::ClosePath,
            ],
            stroke_color: Some(Color {
                r: inf,
                g: ninf,
                b: nan,
            }),
            fill_color: None,
            stroke_width: inf,
            dash_pattern: Some((vec![inf, nan, ninf], inf)),
            ..PathContent::default()
        };

        let nif = path_to_nif(path, 0);

        let (max, min) = (f32::MAX, -f32::MAX);
        assert_eq!(
            nif.bbox,
            RectNif {
                x: f32::MAX,
                y: -f32::MAX,
                width: 0.0,
                height: f32::MAX,
            }
        );
        assert_eq!(
            nif.operations,
            vec![
                PathOpNif::MoveTo(max, min),
                PathOpNif::LineTo(0.0, max),
                PathOpNif::CurveTo(max, min, 0.0, max, min, 0.0),
                PathOpNif::Rectangle(max, min, 0.0, max),
                PathOpNif::ClosePath,
            ]
        );
        let stroke = nif.stroke_color.expect("stroke colour kept");
        assert_eq!((stroke.r, stroke.g, stroke.b), (max, min, 0.0));
        assert_eq!(nif.stroke_width, max);
        assert_eq!(nif.dash_pattern, Some((vec![max, 0.0, min], max)));
    }
}
