use pdf_oxide::elements::{LineCap, LineJoin, PathContent, PathOperation};
use rustler::{Encoder, Env, NifMap, NifUnitEnum, Term};

use crate::{
    atoms,
    color::{color_to_nif, RgbNif},
    geometry::{rect_to_nif, RectNif},
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
#[derive(Debug, Clone, Copy)]
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
            PathOperation::MoveTo(x, y) => PathOpNif::MoveTo(x, y),
            PathOperation::LineTo(x, y) => PathOpNif::LineTo(x, y),
            PathOperation::CurveTo(c1x, c1y, c2x, c2y, ex, ey) => {
                PathOpNif::CurveTo(c1x, c1y, c2x, c2y, ex, ey)
            }
            PathOperation::Rectangle(x, y, w, h) => PathOpNif::Rectangle(x, y, w, h),
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
        stroke_width: path.stroke_width,
        line_cap: path.line_cap.into(),
        line_join: path.line_join.into(),
        dash_pattern: path.dash_pattern,
        layer: path.layer,
    }
}
