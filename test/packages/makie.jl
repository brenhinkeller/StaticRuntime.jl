# Makie (the latest release): a scene, and a figure with an axis and a plot, made before the program is compiled and prepared for it (`StaticRuntime.prepare!`), that the program reads and changes. The nodes of a plot are read
# and set through `StaticRuntime.typed_node` and `StaticRuntime.typed_input` (see the manual, "Makie").
using Makie
const MK_CP = Makie.ComputePipeline

const MK_SCENE = Scene(size = (200, 100))
StaticRuntime.prepare!(MK_SCENE)

function mk_scenes(s, found = Any[])
    s in found || push!(found, s)
    foreach(c -> mk_scenes(c, found), s.children)
    return found
end
const MK_FIG = Figure(size = (300, 200))
const MK_AX = Axis(MK_FIG[1, 1])
const MK_PLOT = lines!(MK_AX, 1:10, Float64.(1:10) .^ 2)
for s in mk_scenes(MK_FIG.scene)
    StaticRuntime.prepare!(s)
    foreach(p -> StaticRuntime.prepare!(p.attributes), s.plots)
end
const MK_POSITIONS = StaticRuntime.typed_node(MK_PLOT.attributes, :positions)
const MK_YS = StaticRuntime.typed_input(MK_PLOT.attributes, :arg2)
const MK_LINEWIDTH = StaticRuntime.typed_node(MK_PLOT.attributes, :linewidth)
const MK_SET_LINEWIDTH = StaticRuntime.typed_input(MK_PLOT.attributes, :linewidth)

@testset "Makie" begin
    # (the cases change the scene: each sets what it reads, so that they are independent of each other)
    @testset "a scene" begin
        check_cases([
            "its size, after a resize"   => () -> (MK_SCENE.viewport[] = Rect2i(0, 0, 250 + opaque(0), 100); println(size(MK_SCENE)); 0),
            "update! of its graph"       => () -> (MK_CP.update!(MK_SCENE.compute, viewport = Rect2i(0, 0, 400 + opaque(0), 100)); println(Int((MK_SCENE.compute[:resolution][]::Vec2d)[1])); 0),
            "a property of its graph"    => () -> (MK_SCENE.compute.viewport = Rect2i(0, 0, 350 + opaque(0), 100); println(Int((MK_SCENE.compute[:resolution][]::Vec2d)[1])); 0),
            "the camera, after a resize" => () -> (MK_SCENE.viewport[] = Rect2i(0, 0, 300 + opaque(0), 100); println(round(Int, MK_SCENE.camera.pixel_space[][1, 1] * 1e5)); 0),
        ])
    end
    # (a program of its own: each graph of the figure is connected with the others)
    @testset "a plot in a figure" begin
        check_cases([
            "its positions"             => () -> (println(round(Int, Float64(MK_POSITIONS[][3][1])) + opaque(0)); 0), # (x, which the other cases do not change)
            "new data"                  => () -> (MK_YS[] = Float64[i * 10 + opaque(0) for i in 1:10]; println(MK_POSITIONS[][3]); 0),
            "new data twice"            => () -> (MK_YS[] = Float64[i * 10 + opaque(0) for i in 1:10]; a = MK_POSITIONS[][3][2]; MK_YS[] = Float64[i * 100 + opaque(0) for i in 1:10]; println(a + MK_POSITIONS[][3][2]); 0),
            "its linewidth"             => () -> (MK_SET_LINEWIDTH[] = 3.0 + opaque(0); println(MK_LINEWIDTH[]); 0),
        ])
    end
end

# CairoMakie: scenes drawn by the program to a PNG (`StaticRuntime.typed_drawing`, made before compiling). What the program writes is the same as what Julia writes (the case prints a checksum of the file), and that is the same as
# what CairoMakie draws itself.
using CairoMakie, CRC32c
const MK_DRAW_DIR = mktempdir()
const MK_LINES_SCENE = Scene(size = (200, 100), camera = campixel!)
lines!(MK_LINES_SCENE, Float64[10, 100, 190], Float64[90, 10, 80]; color = :red, linewidth = 3)
const MK_LINES_DRAWING = StaticRuntime.typed_drawing(MK_LINES_SCENE)
const MK_SCATTER_SCENE = Scene(size = (200, 100), camera = campixel!)
lines!(MK_SCATTER_SCENE, Float64[10, 100, 190], Float64[90, 10, 80]; color = :red, linewidth = 3)
scatter!(MK_SCATTER_SCENE, Float64[10, 100, 190], Float64[90, 10, 80]; color = :blue, markersize = 12)
const MK_SCATTER_DRAWING = StaticRuntime.typed_drawing(MK_SCATTER_SCENE)
# (a figure with an axis: its frame, ticks, grid and the text of its labels, which is drawn with the fonts of the figure)
const MK_DRAWN_FIG = Figure(size = (300, 200))
lines!(Axis(MK_DRAWN_FIG[1, 1]), 1:10, Float64.(1:10) .^ 2)
const MK_FIG_DRAWING = StaticRuntime.typed_drawing(MK_DRAWN_FIG)
mk_png_checksum(drawing, name) = (path = joinpath(MK_DRAW_DIR, name); drawing(path); crc32c(read(path)))
# (what CairoMakie writes for the scene, with the same settings as the drawing)
function mk_cairomakie_png(drawing, name)
    path = joinpath(MK_DRAW_DIR, name)
    screen = CairoMakie.Screen(drawing.scene, drawing.config, nothing, CairoMakie.IMAGE)
    CairoMakie.cairo_draw(screen, drawing.scene)
    CairoMakie.Cairo.write_to_png(screen.surface, path)
    return read(path)
end

@testset "CairoMakie" begin
    @testset "the drawing is CairoMakie's" begin
        for (drawing, name) in ((MK_LINES_DRAWING, "lines"), (MK_SCATTER_DRAWING, "scatter"), (MK_FIG_DRAWING, "figure"))
            drawing(joinpath(MK_DRAW_DIR, name * "_typed.png"))
            @test read(joinpath(MK_DRAW_DIR, name * "_typed.png")) == mk_cairomakie_png(drawing, name * "_cairomakie.png")
        end
    end
    check_cases([
        "lines in a scene"  => () -> (println(mk_png_checksum(MK_LINES_DRAWING, "lines.png")); 0),
        "lines and scatter" => () -> (println(mk_png_checksum(MK_SCATTER_DRAWING, "scatter.png")); 0),
    ])
    check_cases(["a figure with an axis" => () -> (println(mk_png_checksum(MK_FIG_DRAWING, "figure.png")); 0)]) # (a program of its own: it is large)
end
