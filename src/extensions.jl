# Functions that package extensions add methods to: the interface of the Makie extension, declared here so that programs
# and other extensions can call them.

"""
    StaticRuntime.add_listeners!(x)

No longer needed: the listeners of the constants of a program are found when it is compiled. (It does nothing, and gives
`x`.)
"""
add_listeners!(@nospecialize(x)) = x

"""
    StaticRuntime.prepare!(x)

Make `x`, an object that is made before the program is compiled and is a constant of it (a `Makie.Scene`, a
`ComputeGraph`), ready for the program: what its package keeps where the types are lost is made again with the types
that it has now. The methods are in the extensions of the packages. Call it after the object is made and before
compiling, and once: the object is changed.
"""
function prepare! end

"""
    StaticRuntime.typed_node(graph, key; inputs = nothing)

A node of `graph` (a `ComputePipeline.ComputeGraph`, which `prepare!` was called on, and the graphs that it is connected
with) that the program reads as `node[]`, with the types of what it depends on: what the package reads to resolve it
(the edges and inputs that it comes from, and the references of their values) is of types that are not known where it is
read, those of all the nodes of all the graphs. Call it before compiling, and keep it as a constant (`const POSITIONS =
StaticRuntime.typed_node(plot.attributes, :positions)`). With `inputs`, the inputs that the program changes
(`typed_input`s), only what depends on them is resolved when the node is read, and only that is compiled; a change of
another input that the node depends on stops the program with an error that names it. The method is in the extension for
Makie.
"""
function typed_node end

"""
    StaticRuntime.typed_input(graph, key)

An input of `graph` (see `typed_node`) that the program sets as `input[] = value`, which is what
`ComputePipeline.update!(graph; key = value)` does, with what the change reaches (the graphs that depend on the input,
and the listeners of their changes) found before compiling. The value is of the type that the input has then. The method
is in the extension for Makie.
"""
function typed_input end

"""
    drawing = StaticRuntime.typed_drawing(scene; inputs = (), screen_config...)

A drawing of `scene` (a `Makie.Scene`, or a `Makie.Figure`, which is made ready as saving it does: the limits of its
axes are those of what they show) with CairoMakie, that the program makes as `drawing(path)` (an image of the size of
the scene, written to `path` as a PNG) or `drawing(screen)` (on a `CairoMakie.Screen` of the scene). The scene is drawn
once when this is called, which adds to the graphs of its plots what drawing them needs, and they are then prepared
(`prepare!`, which this calls: call it before this, or not at all); each plot is drawn with the types that it has. Call
it before compiling, after the plots are made, and keep it as a constant. `inputs` are the inputs of the plots that the
program changes (`typed_input`s, made before this): what is drawn is what the plots are when it is called, with those
changes (see `typed_node`). Plots that are added afterwards are not drawn. The method is in the extension for
CairoMakie.
"""
function typed_drawing end
