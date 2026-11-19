# CairoMakie in a program: a figure (made before the program is compiled, see the extension for Makie) drawn with Cairo, to an image that the program writes (`Cairo.write_to_png(screen.surface, path)`).

module StaticRuntimeCairoMakieExt

using StaticRuntime: StaticRuntime, @device_override
using CairoMakie: CairoMakie, Makie
using CairoMakie.Makie: Scene, Plot
const Cairo = CairoMakie.Cairo
const CP = Makie.ComputePipeline

# The screen is of the type of what it draws to (`Screen{IMAGE}`, `Screen{PDF}`), which the package reads from the surface when the screen is made (`get_render_type(surface)`, a value of the library): a type that is made when
# the program runs. A surface of an image is always one of `IMAGE`: the screen of one is made here with its type known (the same as the package's, otherwise).
@device_override function CairoMakie.Screen(scene::Scene, config::CairoMakie.ScreenConfig, surface::Cairo.CairoSurfaceImage)
    dsf = CairoMakie.device_scaling_factor(CairoMakie.IMAGE, config)
    CairoMakie.surface_set_device_scale(surface, dsf)
    ctx = Cairo.CairoContext(surface)
    aa = CairoMakie.to_cairo_antialias(config.antialias)
    Cairo.set_antialias(ctx, aa)
    CairoMakie.set_miter_limit(ctx, 2.0)
    return CairoMakie.Screen{CairoMakie.IMAGE}(scene, surface, ctx, dsf, aa, config.visible, config)
end

## Drawing a scene
#
# What the package draws a plot with (`draw_atomic`) first adds to the plot's graph what it needs (`add_constant!`, `map!`, `extract_attributes!`, the nodes and edges of the drawing: done once, a graph that has them keeps them), and
# then reads one node, a `NamedTuple` of all that it draws with, which it gives to a function of Cairo calls (`draw_lineplot(ctx, attributes)`). The plots are those of the scene and its children, in the order of their z
# values (`cairo_draw`). The plots of a program are of many types, all of which are `AbstractPlot` in the scene, and the nodes are read from graphs whose edges and inputs are of all the types of the figure: a drawing is
# made here before the program is compiled, as a list of steps, one for each plot, with its type, its scene and the node that it is drawn with (a `typed_node`), so that each is drawn with the types that it has.

# (one plot: `draw` is given the context and what `attributes` reads; `visible` are the nodes of its visibility and those of the plots that it is in, which all have to be true for it to be drawn; `children`, the steps of the plots
# that it is made of, which are drawn after it, as `draw_plot` does: a `text` has the lines of its LaTeX)
struct PlotStep{P<:Plot,F,N,V<:Tuple,C<:Tuple}
    plot::P
    scene::Scene
    draw::F
    attributes::N
    visible::V
    children::C
end

struct TypedDrawing{S<:Tuple}
    scene::Scene
    config::CairoMakie.ScreenConfig
    steps::S
end

# The function of Cairo calls that the package draws a plot of a type with, from the node `cairo_attributes` (see `draw_atomic` of each type): those of the types that are supported.
draw_function(::Union{Makie.Lines,Makie.LineSegments}) = CairoMakie.draw_lineplot
draw_function(::Makie.Scatter) = CairoMakie.draw_atomic_scatter
draw_function(::Makie.Text) = CairoMakie.draw_text
draw_function(p::Plot) = error("a `", Makie.plotkey(p), "` can not be drawn in a program yet")

all_visible(::Tuple{}) = true
all_visible(nodes::Tuple) = (first(nodes)[]::Bool) && all_visible(Base.tail(nodes))

# A plot that the package draws by reading its attributes one at a time (`poly.color[]`, `poly.model[]`: `draw_poly`), each of which would be a read of a node of any of the graphs: the plot as the drawing functions see it, with
# a `typed_node` for each of its attributes (`nodes`) and the same for the plots that it is made of (`plots`, `poly.plots[2]`); what else is read of it is read from the plot.
struct TypedPlot{P<:Plot,N<:NamedTuple,C<:Tuple,F}
    plot::P
    nodes::N
    plots::C
    scene::Scene # (the scene that it is in, found when the drawing is made: `parent_scene` of the package goes up through plots of any type)
    transform_func::F # (and its transform function, which the package reads from an `Observable{Any}`: as it is when the drawing is made)
end
function Base.getproperty(t::TypedPlot, s::Symbol)
    s === :plots && return getfield(t, :plots)
    nodes = getfield(t, :nodes)
    hasfield(typeof(nodes), s) && return getfield(nodes, s)
    return getproperty(getfield(t, :plot), s)
end
Makie.get_scene(t::TypedPlot) = getfield(t, :scene)
Makie.parent_scene(t::TypedPlot) = getfield(t, :scene)
Makie.transform_func(t::TypedPlot) = getfield(t, :transform_func)
# (the package's methods of these take the plot as `@nospecialize`, and what they call on it is chosen when the program runs: the same, with the stand-in known)
CairoMakie.project_position(t::TypedPlot, space, point, model, yflip::Bool = true) =
    CairoMakie.project_position(Makie.get_scene(t), Makie.transform_func(t), space, point, model, yflip)
function CairoMakie.project_shape(t::TypedPlot, space, rect::Makie.Rect, model)
    res = Makie.get_scene(t).camera.resolution[]
    mini = clamp.(CairoMakie.project_position(t, space, minimum(rect), model), -res, 2 .* res)
    maxi = clamp.(CairoMakie.project_position(t, space, maximum(rect), model), -res, 2 .* res)
    return Makie.Rect(mini, maxi .- mini)
end

# (a `poly`, drawn with the method of `draw_poly` for what it was made of, `K` being `:args` or `:converted`: the package chooses it by the types, with `hasmethod`, which is done when the drawing is made)
struct PolyStep{K,P<:TypedPlot,V<:Tuple}
    poly::P
    scene::Scene
    visible::V
end

# (a plot that was hidden when the drawing was made, and that the program does not show: what it is shown with is checked, and a change of it stops the program, see `typed_node`)
struct HiddenStep{V<:Tuple}
    visible::V
end

@noinline hidden_shown() = error("a plot that was hidden when the drawing was made (`typed_drawing`) is shown: give the inputs that show it in `inputs`")

shown(s::HiddenStep) = (all_visible(s.visible) && hidden_shown(); false)
shown(s) = all_visible(s.visible) && s.scene.visible[]

draw_children(screen::CairoMakie.Screen, ::Tuple{}) = nothing
draw_children(screen::CairoMakie.Screen, steps::Tuple) = (s = first(steps); shown(s) && draw_plot_step(screen, s); draw_children(screen, Base.tail(steps)))

function draw_plot_step(screen::CairoMakie.Screen, s::PlotStep)
    ctx = screen.context
    Cairo.save(ctx)
    s.draw(ctx, s.attributes[])
    Cairo.restore(ctx)
    draw_children(screen, s.children)
    return nothing
end
draw_plot_step(screen::CairoMakie.Screen, s::PolyStep{K}) where {K} = (CairoMakie.draw_poly(s.scene, screen, s.poly, CairoMakie.deref(getproperty(s.poly, K)[])...); nothing)

# (`cairo_draw` and `draw_plot` of the package for one plot: the clipping and translation of its scene are set when the scene is not that of the plot before it)
function draw_step!(screen::CairoMakie.Screen, s, last_scene::Scene)
    shown(s) || return last_scene
    scene = s.scene
    ctx = screen.context
    if scene !== last_scene
        Cairo.restore(ctx)
        Cairo.save(ctx)
        CairoMakie.prepare_for_scene(screen, scene)
        last_scene = scene
    end
    Cairo.save(ctx)
    draw_plot_step(screen, s)
    Cairo.restore(ctx)
    return last_scene
end

# (a generated function, which can not make a closure: one statement for each step, with its type)
@generated function draw_steps!(screen::CairoMakie.Screen, steps::S, last_scene::Scene) where {S<:Tuple}
    return Expr(:block, (:(last_scene = draw_step!(screen, steps[$i], last_scene)) for i in 1:fieldcount(S))..., :(return last_scene))
end

function (d::TypedDrawing)(screen::CairoMakie.Screen)
    ctx = screen.context
    Cairo.save(ctx)
    CairoMakie.draw_background(screen, d.scene)
    Cairo.save(ctx)
    draw_steps!(screen, d.steps, d.scene)
    Cairo.restore(ctx)
    Cairo.restore(ctx)
    return screen
end

# (an image the size of the scene, drawn and written to `path` as a PNG)
function (d::TypedDrawing)(path::AbstractString)
    screen = CairoMakie.Screen(d.scene, d.config, nothing, CairoMakie.IMAGE)
    d(screen)
    Cairo.write_to_png(screen.surface, String(path))
    return path
end

# The graphs of a scene: its own, those of its plots and the plots that they are made of, and those of its children.
function scene_graphs!(graphs::Vector{CP.ComputeGraph}, scene::Scene)
    push!(graphs, scene.compute)
    foreach(p -> plot_graphs!(graphs, p), scene.plots)
    foreach(c -> scene_graphs!(graphs, c), scene.children)
    return graphs
end
function plot_graphs!(graphs::Vector{CP.ComputeGraph}, plot::Plot)
    push!(graphs, plot.attributes)
    foreach(p -> plot_graphs!(graphs, p), plot.plots)
    return graphs
end

# (the visibility of a plot and of the plots that it is in: a plot whose graph has no node `visible` is visible, as `get(plot, :visible, true)` says)
function visible_nodes(plot, inputs)
    nodes = Any[]
    while plot isa Plot
        haskey(plot.attributes.outputs, :visible) && push!(nodes, StaticRuntime.typed_node(plot.attributes, :visible; inputs))
        plot = parent(plot)
    end
    return Tuple(nodes)
end

# (a node of a plot that can not be resolved is one that drawing it does not read: it is not there)
function typed_plot(plot::Plot, inputs)
    names, nodes = Symbol[], Any[]
    for key in keys(plot.attributes.outputs)
        node = try StaticRuntime.typed_node(plot.attributes, key; inputs) catch; nothing end
        node === nothing && continue
        push!(names, key)
        push!(nodes, node)
    end
    return TypedPlot(plot, NamedTuple{Tuple(names)}(Tuple(nodes)), Tuple(typed_plot(p, inputs) for p in plot.plots), Makie.parent_scene(plot)::Scene, Makie.transform_func(plot))
end

# (what `draw_plot` of the package does with a `poly`: the method of `draw_poly` for its arguments as they were given, or for what they were converted to; otherwise it is drawn as the plots that it is made of)
function poly_step(poly::Makie.Poly, inputs, visible)
    scene = Makie.parent_scene(poly)::Scene
    for key in (:args, :converted)
        args = CairoMakie.deref(getproperty(poly, key)[])
        if hasmethod(CairoMakie.draw_poly, Tuple{Scene,CairoMakie.Screen,typeof(poly),typeof.(args)...})
            t = typed_plot(poly, inputs)
            return PolyStep{key,typeof(t),typeof(visible)}(t, scene, visible)
        end
    end
    error("a `poly` of a `", join(typeof.(CairoMakie.deref(poly.converted[])), ", "), "` can not be drawn in a program yet")
end

function plot_step(plot::Plot, inputs)
    visible = visible_nodes(plot, inputs)
    # (hidden, and not shown by anything that the program changes)
    if !all(v -> v[]::Bool, visible) && all(v -> isempty(getfield(v, :steps)), visible)
        return HiddenStep(visible)
    end
    plot isa Makie.Poly && return poly_step(plot, inputs, visible)
    f = draw_function(plot)
    scene = Makie.parent_scene(plot)::Scene
    children = Tuple(plot_step(p, inputs) for p in sort(plot.plots; by = Makie.zvalue2d))
    return PlotStep(plot, scene, f, StaticRuntime.typed_node(plot.attributes, :cairo_attributes; inputs), visible, children)
end

# (a figure: what saving or showing it does first, `update_state_before_display!`, which sets the limits of its axes to what they show, and then its scene)
function StaticRuntime.typed_drawing(fig::Makie.Figure; kwargs...)
    Makie.update_state_before_display!(fig)
    return StaticRuntime.typed_drawing(fig.scene; kwargs...)
end

function StaticRuntime.typed_drawing(scene::Scene; inputs = (), screen_config...)
    makie = Base.get_extension(StaticRuntime, :StaticRuntimeMakieExt)
    config = Makie.merge_screen_config(CairoMakie.ScreenConfig, Dict{Symbol,Any}(screen_config))
    # (the nodes that are given a reference of their own type are made so before anything is resolved: see `declare_node_types!`)
    foreach(makie.declare_node_types!, scene_graphs!(CP.ComputeGraph[], scene))
    # the drawing, done once: what it adds to the graphs of the plots is there for the program
    screen = CairoMakie.Screen(scene, config)
    CairoMakie.cairo_draw(screen, scene)
    foreach(StaticRuntime.prepare!, scene_graphs!(CP.ComputeGraph[], scene))
    plots = Makie.collect_atomic_plots(scene; is_atomic_plot = CairoMakie.is_cairomakie_atomic_plot_or_rasterized)
    sort!(plots; by = Makie.zvalue2d)
    return TypedDrawing(scene, config, Tuple(plot_step(p, inputs) for p in plots))
end

end # module
