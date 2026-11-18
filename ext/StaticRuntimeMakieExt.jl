# Makie in a program (the latest release only). What Makie writes to keep Julia from
# compiling for each type, or in a way that the types of the values are lost, is written again here with the types known.

module StaticRuntimeMakieExt

using StaticRuntime: StaticRuntime, @device_override, add_callback!, call_callback
using Makie: Makie, Scene, SSAO, Attributes

# The finalizer of a `Scene` frees what the screens of a backend hold: there are no screens that the program has not closed
@device_override Base.finalizer(f::Function, scene::Scene) = scene

# The pairs of the attributes: the value is of any type, and `Pair(key, value)` takes the type of the pair from the type of the value
@device_override function Base.iterate(x::Attributes, state...)
    s = iterate(keys(x), state...)
    s === nothing && return nothing
    return (Pair{Symbol,Any}(s[1], x[s[1]]), s[2])
end

# The defaults of the `SSAO` are the attributes of the theme, with values of the types of its fields. The theme for a key may be given as anything (`theme` is inferred as a union with `Nothing`,
# `Observable` and `NamedTuple`), and the call of the constructor with each of them is not one that can be split
@device_override function Makie.SSAO(; radius = nothing, bias = nothing, blur = nothing)
    defaults = Makie.theme(nothing, :SSAO)::Attributes
    _radius = isnothing(radius) ? defaults.radius[]::Float32 : radius
    _bias = isnothing(bias) ? defaults.bias[]::Float32 : bias
    _blur = isnothing(blur) ? defaults.blur[]::Int32 : blur
    return SSAO(_radius, _bias, _blur)
end

# The default gaps of a `GridLayout` are those of the theme: GridLayoutBase calls a function that Makie keeps in a `Ref` (`DEFAULT_COLGAP_GETTER[]()`, set when Makie is loaded), and the call of a function
# that is stored where its type is lost is the call of any function. The functions that are stored are these, with the same result
# (`theme(key; default)` is a union of types, `Nothing`, `Attributes`, `Observable` and an abstract `NamedTuple`, so the theme is read here: what it gives for a key that is in it)
function theme_gap(key::Symbol, default::Float64)
    t = Makie.current_default_theme()
    haskey(t, key) || return default
    return convert(Float64, Makie.to_value(t[key])::Real)
end
@device_override Makie.GridLayoutBase.get_default_colgap()::Float64 = theme_gap(:colgap, Float64(Makie.GridLayoutBase.DEFAULT_COLGAP[]))
@device_override Makie.GridLayoutBase.get_default_rowgap()::Float64 = theme_gap(:rowgap, Float64(Makie.GridLayoutBase.DEFAULT_ROWGAP[]))

# The compute graph. A graph that is made when the program is compiled is embedded in it, and the edges that were resolved then have a `TypedEdge`, with the types of what they hold. What it does not have is the names of the
# outputs: `resolve!` makes the `last` of a callback as `NamedTuple{names}(vals)` with the names read from the nodes, which are values and not types, so the type of `last` (that a callback reads `last.chunk_u8` of) is lost.
# `name_outputs!` makes the outputs of the typed edges a `NamedTuple` (the names are then in the type), and `resolve!` of those is the same with `last` being the outputs.
const CP = Makie.ComputePipeline

"""
    name_outputs!(graph)

Gives the typed edges of the resolved edges of `graph` outputs that have their names in their type (see above). Done once, when the program is compiled, after the graph was resolved.
"""
function name_outputs!(graph::CP.ComputeGraph)
    for node in values(graph.outputs)
        edge = node.parent
        edge isa CP.ComputeEdge && isassigned(edge.typed_edge) || continue
        te = edge.typed_edge[]
        te.outputs isa NamedTuple && continue
        names = ntuple(i -> edge.outputs[i].name, length(edge.outputs))
        edge.typed_edge[] = CP.TypedEdge(te.callback, te.inputs, te.inputs_dirty, NamedTuple{names}(te.outputs), te.output_nodes)
    end
    return graph
end

# What a graph does when its outputs change (`graph.onchange`, a listener that `ComputeGraph()` makes): for each key that changed, the value of the output is set in the observable of the key (a copy of it, if the observable was made with
# `use_deepcopy`, and only if it is not equal to what the observable has), and then the observables are notified. The package does it with the keys as values: the node and the observable of a key are got from dictionaries, of
# the types `Computed` and `Observable` (of any type of value), and the value is an `Any`. It is the one method that all the observables of a graph go through, and it was inferred over all the types that there are (it took minutes).
# The same is made with the types known (`stage_onchange!`): a table with an entry for each key that has an observable, in a tuple, so that the type of the observable, and of the reference that the node keeps its value in, are in
# the type of the table, and the loop over the keys is one block of statements for each of them (`stage_apply!`). An observable that is added to the graph afterwards is not in the table.
struct StagedEntry{T,R<:CP.RefValue,D}
    key::Symbol
    node::CP.Computed
    ref::R                      # (the reference that the value of the node is in: it is the same one for as long as the node is)
    obs::Makie.Observables.Observable{T}
end

struct StagedOnChange{G,TB<:Tuple}
    graph::G
    table::TB
end

# (one key: the value of its output is set in its observable)
@noinline function stage_apply_one!(e::StagedEntry{T,R,D}, changeset::Set{Symbol}) where {T,R,D}
    e.key in changeset || return nothing
    e.node[] # (the node is resolved if it is not yet: what the package does by reading `graph.outputs[key][]`)
    val = e.ref[]
    new = val isa T ? val : convert(T, val)
    if !D
        setfield!(e.obs, :val, new)
    elseif !isequal(new, getfield(e.obs, :val))
        setfield!(e.obs, :val, deepcopy(new)::T)
    else
        delete!(changeset, e.key) # (the same value: it is not notified)
    end
    return nothing
end

@noinline function stage_notify_one!(e::StagedEntry, changeset::Set{Symbol})
    e.key in changeset && notify(e.obs)
    return nothing
end

@generated function stage_apply!(table::TB, changeset) where {TB<:Tuple}
    return Expr(:block, (:(stage_apply_one!(table[$i], changeset)) for i in 1:fieldcount(TB))..., :(return nothing))
end
@generated function stage_notify!(table::TB, changeset) where {TB<:Tuple}
    return Expr(:block, (:(stage_notify_one!(table[$i], changeset)) for i in 1:fieldcount(TB))..., :(return nothing))
end

function (f::StagedOnChange)(changeset::Set{Symbol})
    stage_apply!(f.table, changeset)
    stage_notify!(f.table, changeset)
    empty!(changeset)
    return Makie.Observables.Consume(false)
end

# The listener of `graph.onchange` that the package made is replaced with one that has the table. (The graph is resolved first: the references of the nodes are the ones that the program has.)
function stage_onchange!(graph::CP.ComputeGraph)
    for node in values(graph.outputs)
        node[]
    end
    entries = Any[]
    for (key, obs) in graph.observables
        node = graph.outputs[key]
        ref = node.value
        push!(entries, StagedEntry{eltype(obs),typeof(ref),key in graph.should_deepcopy}(key, node, ref, obs))
    end
    table = Tuple(entries)
    listeners = graph.onchange.listeners
    for i in eachindex(listeners)
        p = listeners[i]
        # (the one that `ComputeGraph()` makes is a closure of the module of the package, that has the graph)
        if parentmodule(typeof(p.second)) === CP && occursin("ComputeGraph", string(nameof(typeof(p.second))))
            listeners[i] = Pair{Int,Any}(p.first, StagedOnChange(graph, table))
        end
    end
    return graph
end

"""
    prepare!(graph::ComputeGraph)
    prepare!(scene::Scene)

Make a graph (the `compute` of a scene) that was made before the program is compiled ready for it: it is resolved, the typed edges have the names of their outputs (`name_outputs!`), what it does when its outputs change has the types of the
observables of the graph (`stage_onchange!`), and the listeners of the observables are said (`add_listeners!`). Call it once, after the observables that the program uses are asked for (`get_observable!`).
"""
# Makie keeps the value of some nodes in a `RefValue{Any}` (the `shading` of a scene is `Automatic`, or a `ShadingAlgorithm`, and the reference is of the type `Any` so that either can be stored), and what is read from a reference of
# that type is a value of any type: the slot is one that all of the references of the type `Any` of the program share, and the callbacks that get the value are compiled for all the types that anything stores in one. The
# nodes that are known to have a few types of value get a reference of the union of them: it is made again with the value that it has, before the graph is resolved (the typed edges keep the references that the nodes
# have when they are resolved). The list is of the nodes of the scene that were found to need it.
const DECLARED_NODE_TYPES = Dict{Symbol,Any}(:shading => Union{Makie.Automatic,Makie.ShadingAlgorithm})

function declare_node_types!(graph::CP.ComputeGraph)
    for (key, T) in DECLARED_NODE_TYPES
        node = get(graph.outputs, key, nothing)
        node === nothing && continue
        if !isdefined(node, :value)
            # (an input that is not resolved yet has no reference: it is made when it is resolved, as `RefValue{Any}` here: made now, with the value that the function of the input gives)
            input = get(graph.inputs, key, nothing)
            input === nothing && continue
            value = input.f(input.value)
            value isa T && (node.value = Base.RefValue{T}(value))
            continue
        end
        ref = node.value
        ref isa Base.RefValue{Any} || continue
        # (an input that is not resolved yet: the value is the one that its function gives)
        input = get(graph.inputs, key, nothing)
        value = if input !== nothing && input.dirty
            input.f(input.value) # (an input that is not resolved: what the reference has is a placeholder, `nothing`)
        elseif isassigned(ref)
            ref[]
        else
            nothing
        end
        value isa T || continue
        edges_typed = any(n -> n.parent isa CP.ComputeEdge && isassigned(n.parent.typed_edge) && any(r -> r === ref, (n.parent.typed_edge[].inputs..., n.parent.typed_edge[].outputs...)), values(graph.outputs))
        edges_typed && (@warn "the node `$key` of a graph is resolved: its reference can not be made again with the type of its value" maxlog = 1; continue)
        node.value = Base.RefValue{T}(value)
    end
    return graph
end

function StaticRuntime.prepare!(graph::CP.ComputeGraph)
    declare_node_types!(graph)
    for node in values(graph.outputs)
        node[] # (the nodes are resolved first: each has the reference of its value)
    end
    for input in values(graph.inputs)
        input.f isa StagedInputFunction || (input.f = StagedInputFunction(input.f, input.output.value))
        add_callback!(InputFunction, typeof(input.f))
    end
    stage_onchange!(graph)
    name_outputs!(graph)
    StaticRuntime.add_listeners!(graph)
    return graph
end
StaticRuntime.prepare!(scene::Scene) = (StaticRuntime.prepare!(scene.compute); StaticRuntime.add_listeners!(scene); scene)

# (an edge that gives its inputs as its outputs, which a node of another graph is connected with: the method of the package for it, which the one below would be used in place of)
@device_override function CP.resolve!(edge::CP.TypedEdge{IT,OT,typeof(CP.compute_identity)}) where {IT,OT<:NamedTuple}
    for i in eachindex(edge.inputs_dirty)
        edge.output_nodes[i].dirty |= edge.inputs_dirty[i]
    end
    return
end

@device_override @noinline function CP.resolve!(edge::CP.TypedEdge{<:Any,<:NamedTuple})
    if any(edge.inputs_dirty)
        dirty = CP._get_named_change(edge.inputs, edge.inputs_dirty)
        result = edge.callback(map(getindex, edge.inputs), dirty, map(getindex, edge.outputs))
        if result isa Tuple
            length(result) == length(edge.outputs) || CP.throw_length_mismatch(edge, result)
            CP.set_result!(edge, result)
        elseif isnothing(result)
            foreach(x -> x.dirty = false, edge.output_nodes)
        else
            CP.throw_invalid_result(result)
        end
    end
    return
end

# `set_result!` takes the results one at a time, by recursion on the tuple with the number of the output, which is read as `edge.outputs[i]`: an index that is not a constant is a read of one of the references of all the outputs, and
# `is_same` of it and the value is a call over the pairs of all their types. Each output is done here with its own reference and the value of its own type, as one statement for each (`set_results!`).
@inline function set_one_result!(ref, node, value)
    if isnothing(value) || CP.is_same(ref[], value)
        node.dirty = false
    else
        node.dirty = true
        ref[] = CP.deref(value)
    end
    return nothing
end

@generated function set_results!(edge::CP.TypedEdge{IT,OT}, result::Tuple) where {IT,OT<:NamedTuple}
    return Expr(:block, (:(set_one_result!(edge.outputs[$i], edge.output_nodes[$i], result[$i])) for i in 1:fieldcount(OT))..., :(return nothing))
end

@device_override CP.set_result!(edge::CP.TypedEdge{<:Any,<:NamedTuple}, result::Tuple) = set_results!(edge, result)

# What a function that is given to `map!` gives is of any type where inference does not know it (`lighting_mode` gives the `shading`, which is an `Any`, or a `ShadingAlgorithm`), and the tuple that is made of it is made of
# the runtime (`jl_f_tuple`), and `set_result!` reads it by the index. The outputs of an edge have the types that they had when the graph was resolved, and `last` (what the edge has now) says them: the result is converted to
# each of them, which is what storing it in the `RefValue` does (`nothing` and a `RefValue` are as they are: see `set_result!`).
narrow_result(::Type{T}, x) where {T} = x === nothing ? x : x isa Base.RefValue ? x : convert(T, x)

@device_override function (x::CP.MapFunctionWrapper{true})(inputs, @nospecialize(changed), cached)
    result = x.user_func(values(inputs)...)
    cached isa NamedTuple || return (result,)
    return (narrow_result(fieldtype(typeof(cached), 1), result),)
end

# (the tuple that has the types of the outputs: `Tuple{fieldtypes(...)...}` of the named tuple that `last` is)
@generated output_tuple(::Type{NT}) where {NT<:NamedTuple} = Tuple{fieldtypes(NT)...}

@device_override function (x::CP.MapFunctionWrapper{false})(inputs, @nospecialize(changed), cached)
    result = x.user_func(values(inputs)...)
    (cached isa NamedTuple && result isa Tuple) || return result
    R = output_tuple(typeof(cached))
    result isa R || error("a function of a compute graph gave values that do not have the types of its outputs (", typeof(result), " for ", R, "): the program stops, as the types of the outputs are those of the graph when it was compiled")
    return result::R
end

# The first resolve of an edge makes its `TypedEdge`, with types that are made when it runs (`NamedTuple{names}`, `Base.invokelatest`). The edges of a program are resolved when it is compiled (`name_outputs!` is called after that),
# so that the call is not one that the program makes.
@device_override CP.TypedEdge(edge::CP.ComputeEdge) = error("an edge of a compute graph is resolved for the first time when the program runs: resolve the graph when it is compiled")

# `update!(graph; name = value, ...)` makes a `Pair{Symbol,Any}` of each, which holds a value of any type (its field is an `Any` that anything that makes one stores in), and the values are read from them as an `Any`.
# The keywords are the values with their types, and are set as they are.
@device_override function CP.update!(attr::CP.ComputeGraph; kwargs...)
    return lock(attr.lock) do
        for (key, value) in kwargs
            haskey(attr.inputs, key) || error("Attribute ", key, " not found in ComputeGraph")
            CP._setproperty!(attr, key, value)
        end
        CP.update_observables!(attr)
        return attr
    end
end

# The value of an input is of any type, and `input.value = value` is a call of `setproperty!` that Julia chooses a method of by the type of the value (`Input` has methods for an `Observable` and a `Computed`, which are
# errors), which is a call that is made when the program runs. The field is set here, with what these do for any other type.
@device_override function Base.setindex!(input::CP.Input, @nospecialize(value))
    CP.is_same(input.value, value) && return value
    setfield!(input, :value, value)
    CP.mark_dirty!(input)
    CP.update_observables!(input)
    return value
end

# (the package writes the value of these two as `@nospecialize`, so that they are compiled once, for a value of the type `Any`: a value that is then compared with the one that the input has (`is_same`), a call over the
# pairs of all the types that a value can have. They are written again here for the type of each value.)
@device_override function Base.setproperty!(attr::CP.ComputeGraph, key::Symbol, value)
    return lock(attr.lock) do
        CP._setproperty!(attr, key, value)
        foreach(notify, attr.obs_to_update)
        return value
    end
end

@device_override function CP._setproperty!(attr::CP.ComputeGraph, key::Symbol, value)
    input = attr.inputs[key]::CP.Input{CP.ComputeGraph} # (the dictionary has the type `Input`, which has no fields that are of one type)
    CP.is_same(input.value, value) && return value
    CP.mark_dirty!(input)
    setfield!(input, :value, value)
    return value
end

# An input is resolved: its function is called with its value, and the value of its node is set, and the edges that depend on it are told. The package makes the reference of the node when there is none, as
# `RefValue(value)`: a type that is made when the program runs (the nodes of a program are resolved when it is compiled, and have theirs), and it sets the value in the reference that it reads from the node, whose type is not
# known (`Computed` has the type `RefValue` of it): `prepare!` makes the function of each input one that has the reference (`StagedInputFunction`), with its type, and it sets the value itself.
struct InputFunction end # (the tag of the callbacks that are the functions of the inputs: see `call_callback`)

struct StagedInputFunction{F,R<:CP.RefValue} <: Function
    f::F
    ref::R
end
function (s::StagedInputFunction)(x)
    s.ref[] = CP.deref(s.f(x))
    return nothing
end

@device_override function CP.resolve!(input::CP.Input{CP.ComputeGraph})
    input.dirty || return nothing
    call_callback(InputFunction, input.f, input.value) # (the function of an input is one of those of the inputs of the graph: `prepare!` says which)
    input.dirty = false
    input.output.dirty = true
    for edge in input.dependents
        CP.mark_input_dirty!(input, edge)
    end
    input.output.dirty = false
    return input.output.value[]
end

# The observable of a node of the graph is made when it is first asked for, of the type of the value that the node has then (`Observable{eltype(val.value)}`): a type that is made when the program runs.
# The observables of a program are the ones that were asked for when it was compiled (`get_observable!(graph, name)`, or `on(f, graph[name])`), and what is asked for later is one of these.
@device_override CP.get_observable!(attr::CP.ComputeGraph, key::Symbol; use_deepcopy = true) = attr.observables[key]

end # module
