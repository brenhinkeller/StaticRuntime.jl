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
        # (the one that `ComputeGraph()` makes is a closure of the module of the package, that has the graph; or the one that was made here before, by a `prepare!` before nodes were added: `typed_drawing`)
        if p.second isa StagedOnChange || parentmodule(typeof(p.second)) === CP && occursin("ComputeGraph", string(nameof(typeof(p.second))))
            listeners[i] = Pair{Int,Any}(p.first, StagedOnChange(graph, table))
        end
    end
    return graph
end


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

"""
    prepare!(graph::ComputeGraph)
    prepare!(scene::Scene)

Make a graph (the `compute` of a scene) that was made before the program is compiled ready for it: it is resolved, the typed edges have the names of their outputs (`name_outputs!`), what it does when its outputs change has the types of the
observables of the graph (`stage_onchange!`). Call it once, after the observables that the program uses are asked for (`get_observable!`). (The listeners of the observables are found when the program is compiled.)
"""
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
    return graph
end
StaticRuntime.prepare!(scene::Scene) = (StaticRuntime.prepare!(scene.compute); scene)

# A node that is read (`graph[key][]`) is resolved by the package by reading what it comes from: `resolve!(computed.parent)`, the parent being an `AbstractEdge` (an edge or an input), `edge.typed_edge[]` (a `RefValue{TypedEdge}`),
# `input.f` (a `Function`) and `computed.value[]` (a `RefValue`). The nodes of a figure are connected (a plot's graph with its scene's), so what these hold is what all the nodes of all the graphs hold (an input function of each of
# about 200 types): a read of any node would be compiled for all of them. `typed_node` finds what the node comes from when the program is compiled, and makes it a list of steps, in the order that the package resolves them
# (what an edge depends on before it), each with the types of its own edge or input; reading the node is doing the steps and reading its reference. A step does nothing when what it resolves is not dirty, as in the package (an
# input that changed makes everything that depends on it dirty: `mark_dirty!`).
struct InputStep{F,V}
    input::CP.Input{CP.ComputeGraph}
    f::F # (the function of the input, a `StagedInputFunction` that sets the reference of the node: see `prepare!`)
end

struct EdgeStep{TE<:CP.TypedEdge,IT<:Tuple}
    edge::CP.ComputeEdge{CP.ComputeGraph}
    typed::TE # (`IT`: the types of the values of its inputs when the program was compiled, see `typed_inputs`)
end

# (`fixed`: the inputs that the node depends on and that are not steps, when the inputs that the program changes were given: see `typed_node`. `V`: the type of the value, which is that of the reference, or the type of what
# it had when the program was compiled for a reference of an abstract type, `RefValue{Any}`: one of another type stops the program, as for the inputs of an edge)
struct TypedNode{V,R<:Base.RefValue,S<:Tuple}
    node::CP.Computed
    ref::R
    steps::S
    fixed::Vector{CP.Input{CP.ComputeGraph}}
end

@noinline function run_step!(s::InputStep{F,V}) where {F,V}
    input = s.input
    input.dirty || return nothing
    value = input.value
    # (the type of the value of the input when the program was compiled: one of another type, set by the program, is one that the steps were not made for)
    value isa V || error("the input `", input.name, "` of a compute graph was given a value of another type than it had when the program was compiled (", V, "): call `typed_node` with the value of that type")
    s.f(value::V)
    input.dirty = false
    input.output.dirty = true
    for edge in input.dependents
        CP.mark_input_dirty!(input, edge)
    end
    input.output.dirty = false
    return nothing
end

@noinline function run_step!(s::EdgeStep)
    edge = s.edge
    CP.isdirty(edge) || return nothing
    lock(edge.graph.lock)
    try
        resolve_step!(s.typed, s)
        edge.got_resolved[] = true
        fill!(edge.inputs_dirty, false)
        for dep in edge.dependents
            CP.mark_input_dirty!(edge, dep)
        end
        for node in edge.outputs
            node.dirty = false
        end
    finally
        unlock(edge.graph.lock)
    end
    return nothing
end

# The references of some nodes are `RefValue{Any}` (Makie's `args` and `dim_converted` of a plot: their type can change), and what a callback is given of them is an `Any`, which it splats (`convert_arguments(P, args...)`): the
# inputs of an edge are read here as the types that they had when the program was compiled. One of another type stops the program, as one of the outputs does (`narrow_result`).
@noinline input_type_error(name::Symbol, @nospecialize(T)) = error("the node `", name, "` of a compute graph has a value of another type than it had when the program was compiled (", T, ")")

@generated function typed_inputs(inputs::NamedTuple{N}, ::Type{IT}) where {N,IT<:Tuple}
    reads = map(1:length(N)) do i
        T = fieldtype(IT, i)
        :(let v = inputs[$i][]; v isa $T || input_type_error($(QuoteNode(N[i])), $T); v::$T end)
    end
    return :(NamedTuple{N}(($(reads...),)))
end

# (the same as `resolve!` of a typed edge above, with the inputs read as their types)
function resolve_step!(edge::CP.TypedEdge{<:Any,<:NamedTuple}, ::EdgeStep{TE,IT}) where {TE,IT}
    if any(edge.inputs_dirty)
        dirty = CP._get_named_change(edge.inputs, edge.inputs_dirty)
        result = edge.callback(typed_inputs(edge.inputs, IT), dirty, typed_outputs(edge.outputs))
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
resolve_step!(edge::CP.TypedEdge{<:Any,<:NamedTuple,typeof(CP.compute_identity)}, ::EdgeStep) = CP.resolve!(edge)

@generated function run_steps!(steps::S) where {S<:Tuple}
    return Expr(:block, (:(run_step!(steps[$i])) for i in 1:fieldcount(S))..., :(return nothing))
end

@noinline fixed_input_changed(input::CP.Input) = error("the input `", input.name, "` of a compute graph was changed, and the node that is read was made (`typed_node`, `typed_drawing`) for changes of other inputs: give it in `inputs`")

function check_fixed(fixed::Vector{CP.Input{CP.ComputeGraph}})
    for input in fixed
        input.dirty && fixed_input_changed(input)
    end
    return nothing
end

function Base.getindex(t::TypedNode{V}) where {V}
    check_fixed(t.fixed)
    run_steps!(t.steps)
    v = t.ref[]
    v isa V || input_type_error(t.node.name, V)
    return v::V
end
# (what the package reads a node or an observable with, when it can be either: `to_value(plot.alpha)`)
Makie.to_value(t::TypedNode) = t[]

# The steps of what `node` comes from, in the order that they are resolved. With `changing` (the inputs that the program changes), only those inputs and the edges that depend on one of them are steps: nothing else can need
# to be resolved again (what an edge depends on can only change if an input that it comes from does), and the other inputs are `fixed`. Whether it depends on one of the inputs that change is what this gives.
function collect_steps!(steps::Vector{Any}, fixed::Vector{CP.Input{CP.ComputeGraph}}, seen::Base.IdDict{Any,Bool}, node::CP.Computed, changing)
    CP.hasparent(node) || return false
    p = node.parent
    haskey(seen, p) && return seen[p]
    if p isa CP.Input
        p.f isa StagedInputFunction || error("a node depends on the input `", p.name, "` of a graph that `StaticRuntime.prepare!` was not called on")
        live = changing === nothing || p in changing
        live ? push!(steps, InputStep{typeof(p.f),typeof(p.value)}(p, p.f)) : push!(fixed, p)
    else
        live = false
        for n in p.inputs
            live |= collect_steps!(steps, fixed, seen, n, changing)
        end
        isassigned(p.typed_edge) && p.typed_edge[].outputs isa NamedTuple || error("a node depends on an edge of a graph that `StaticRuntime.prepare!` was not called on")
        if live
            te = p.typed_edge[]
            IT = Tuple{(isconcretetype(eltype(r)) ? eltype(r) : typeof(r[]) for r in values(te.inputs))...}
            push!(steps, EdgeStep{typeof(te),IT}(p, te))
        end
    end
    seen[p] = live
    return live
end

function StaticRuntime.typed_node(graph::CP.ComputeGraph, key::Symbol; inputs = nothing)
    node = graph.outputs[key]
    node[]
    steps = Any[]
    fixed = CP.Input{CP.ComputeGraph}[]
    changing = inputs === nothing ? nothing : Base.IdSet{Any}(i.input for i in inputs)
    collect_steps!(steps, fixed, Base.IdDict{Any,Bool}(), node, changing)
    ref = node.value
    V = isconcretetype(eltype(ref)) ? eltype(ref) : typeof(ref[])
    return TypedNode{V,typeof(ref),typeof(Tuple(steps))}(node, ref, Tuple(steps), fixed)
end

# An input that the program sets (`input[] = value`, as `update!(graph; key = value)` does). The package then notifies the observables in `graph.obs_to_update` (a `Vector{Observable}`, of the `onchange` of each graph that the change
# reaches), which is a call over all the observables of the program and all their listeners: the graphs that the input reaches are found when it is made, and their `onchange` and its listeners are kept with their types.
struct TypedInput{V,L<:Tuple}
    input::CP.Input{CP.ComputeGraph}
    graphs::L # (for each graph that a change of the input reaches: its `onchange`, and a tuple of the listeners of it)
end

function notify_listeners(fs::Tuple, val)
    for f in fs # (a tuple: one call for each, with its type)
        result = f(val)
        result isa Makie.Observables.Consume && result.x && return true
    end
    return false
end

function has_identical(v::Vector, x)
    for y in v
        y === x && return true
    end
    return false
end

@noinline notify_graph(obs, fs::Tuple, pending::Vector) = (has_identical(pending, obs) && notify_listeners(fs, obs.val); nothing)

# (a generated function, which can not make a closure: the work is in the functions that it calls)
@generated function notify_graphs!(graphs::L, pending::Vector) where {L<:Tuple}
    return Expr(:block, (:(notify_graph(graphs[$i][1], graphs[$i][2], pending)) for i in 1:fieldcount(L))..., :(return nothing))
end

function Base.setindex!(t::TypedInput{V}, value) where {V}
    value isa V || error("the input `", t.input.name, "` of a compute graph is set to a value of another type than it had when the program was compiled (", V, ")")
    input = t.input
    graph = input.graph
    lock(graph.lock)
    try
        old = input.value
        old isa V && CP.is_same(old, value) && return value
        setfield!(input, :value, value)
        CP.mark_dirty!(input, graph.obs_to_update)
        notify_graphs!(t.graphs, graph.obs_to_update)
        empty!(graph.obs_to_update)
    finally
        unlock(graph.lock)
    end
    return value
end

function reached_graphs!(found::Vector{Any}, edges)
    for edge in edges
        any(g -> g === edge.graph, found) || push!(found, edge.graph)
        reached_graphs!(found, edge.dependents)
    end
    return found
end

function StaticRuntime.typed_input(graph::CP.ComputeGraph, key::Symbol)
    input = graph.inputs[key]::CP.Input{CP.ComputeGraph}
    graphs = reached_graphs!(Any[graph], input.dependents)
    entries = Tuple((g.onchange, Tuple(l[2] for l in g.onchange.listeners)) for g in graphs)
    return TypedInput{typeof(input.value),typeof(entries)}(input, entries)
end

# (an edge that gives its inputs as its outputs, which a node of another graph is connected with: the method of the package for it, which the one below would be used in place of)
@device_override function CP.resolve!(edge::CP.TypedEdge{IT,OT,typeof(CP.compute_identity)}) where {IT,OT<:NamedTuple}
    for i in eachindex(edge.inputs_dirty)
        edge.output_nodes[i].dirty |= edge.inputs_dirty[i]
    end
    return
end

# What a callback is given as what the outputs have now (`last`), with the types of their references: of one that is a `RefValue{Any}`, `Any` (`map(getindex, outputs)` makes a named tuple of the types of the values, which for
# such a reference is not known, and the type of the output that the result is converted to, `narrow_result`, is then not known either)
@generated function typed_outputs(outputs::NamedTuple{N,RT}) where {N,RT<:Tuple}
    return :(NamedTuple{N,Tuple{$((eltype(fieldtype(RT, i)) for i in 1:length(N))...)}}(($((:(outputs[$i][]) for i in 1:length(N))...),)))
end

@device_override @noinline function CP.resolve!(edge::CP.TypedEdge{<:Any,<:NamedTuple})
    if any(edge.inputs_dirty)
        dirty = CP._get_named_change(edge.inputs, edge.inputs_dirty)
        result = edge.callback(map(getindex, edge.inputs), dirty, typed_outputs(edge.outputs))
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
# (it gives what the function gave as well: in Julia, where the package resolves the input, the package sets the reference of the node to it, which is the same)
function (s::StagedInputFunction)(x)
    result = s.f(x)
    s.ref[] = CP.deref(result)
    return result
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

# What CairoMakie draws lines with (and scatter, for the attributes of each point). The package's message for arguments of lengths that do not fit says their types (`map(typeof, args)`), which are values in a tuple
# there, known only when the program runs, and a type is not something that a program can print then. The same, with the lengths only.
@device_override @generated function Makie.broadcast_foreach_index(f, indices, args...)
    N = length(args)
    return quote
        lengths = Base.Cartesian.@ntuple $N i -> Makie.attr_broadcast_length(args[i])
        maxlen = maximum(lengths)
        any_wrong_length = Base.Cartesian.@nany $N i -> lengths[i] ∉ (0, 1, maxlen)
        if any_wrong_length
            error("All non scalars need same length, Found lengths for each argument: $lengths")
        end
        isempty(indices) && return
        if (maxlen > 1) && (last(indices) > maxlen) # assuming indices sorted
            error("Indices must be in range. Found $(last(indices)) > $maxlen.")
        end
        0 in lengths && return
        for i in indices
            Base.Cartesian.@ncall $N f (j -> Makie.attr_broadcast_getindex(args[j], i))
        end
        return
    end
end

# The bounding box of a segment of a path (what a `BezierPath` is made with, and what drawing a shape that is clipped makes): the package makes its corners as `Point(mi...)` of a `Vector`, a point of as many dimensions as the
# vector has elements, which is known when the program runs. The segments are 2-dimensional (`Point2d`): the same, with the two.
@device_override function Makie.bbox(b::Makie.BezierSegment)
    p0 = b.from
    p1 = b.c1
    p2 = b.c2
    p3 = b.to
    mi = [min.(p0, p3)...]
    ma = [max.(p0, p3)...]
    c = -p0 + p1
    b = p0 - 2p1 + p2
    a = -p0 + 3p1 - 3p2 + 1p3
    for dim in 1:2
        if abs(a[dim]) < 1.0e-12
            if abs(b[dim]) > 1.0e-12
                t = -c[dim] / (2 * b[dim])
                if t > 0 && t < 1
                    s = 1.0 - t
                    q = s * s * s * p0[dim] + 3.0 * s * s * t * p1[dim] + 3.0 * s * t * t * p2[dim] + t * t * t * p3[dim]
                    mi[dim] = min(mi[dim], q)
                    ma[dim] = max(ma[dim], q)
                end
            end
        else
            h = b[dim] * b[dim] - a[dim] * c[dim]
            if h > 0
                h = sqrt(h)
                for sign in (-1, 1)
                    t = (-b[dim] + sign * h) / a[dim]
                    if t > 0 && t < 1
                        s = 1.0 - t
                        q = s * s * s * p0[dim] + 3.0 * s * s * t * p1[dim] + 3.0 * s * t * t * p2[dim] + t * t * t * p3[dim]
                        mi[dim] = min(mi[dim], q)
                        ma[dim] = max(ma[dim], q)
                    end
                end
            end
        end
    end
    lo = Makie.Point2d(mi[1], mi[2])
    return Makie.Rect2d(lo, Makie.Point2d(ma[1], ma[2]) - lo)
end

# The curves of an arc: the package makes them a `Vector{Any}` (`[LineTo(p), curves...]`, of two types of commands, which `vect` promotes to `Any`), which the path converts to its `Vector{PathCommand}` element by element, each of
# any type. The same, as the vector of the path.
@device_override function Makie.elliptical_arc_to_beziers(arc::Makie.EllipticalArc)
    delta_a = abs(arc.a2 - arc.a1)
    n_beziers = ceil(Int, delta_a / 0.5pi)
    angles = range(arc.a1, arc.a2; length = n_beziers + 1)
    startpoint = Makie.Point2d(cos(arc.a1), sin(arc.a1))
    commands = Makie.PathCommand[Makie.LineTo(startpoint)]
    for i in 1:n_beziers
        start, stop = angles[i], angles[i + 1]
        theta = stop - start
        kappa = 4 / 3 * tan(theta / 4)
        c1 = Makie.Point2d(cos(start) - kappa * sin(start), sin(start) + kappa * cos(start))
        c2 = Makie.Point2d(cos(stop) + kappa * sin(stop), sin(stop) - kappa * cos(stop))
        b = Makie.Point2d(cos(stop), sin(stop))
        push!(commands, Makie.CurveTo(c1, c2, b))
    end
    path = Makie.BezierPath(commands)
    path = Makie.scale(path, Makie.Vec2d(arc.r1, arc.r2))
    path = Makie.rotate(path, arc.angle)
    return Makie.translate(path, arc.c)
end

# (the commands of a path that is scaled or moved: the package collects them with the type of what it finds, which `collect` widens as it goes, a type that is made when the program runs; they are converted to `PathCommand`
# by the path, which is what they are made as here, as `rotate` of the package does)
@device_override Makie.scale(bp::Makie.BezierPath, s::Real) = Makie.BezierPath(Makie.PathCommand[Makie.scale(x::Makie.PathCommand, Makie.Vec2d(s, s)) for x in bp.commands])
@device_override Makie.scale(bp::Makie.BezierPath, v::Makie.VecTypes{2}) = Makie.BezierPath(Makie.PathCommand[Makie.scale(x::Makie.PathCommand, v) for x in bp.commands])
@device_override Makie.translate(bp::Makie.BezierPath, v::Makie.VecTypes{2}) = Makie.BezierPath(Makie.PathCommand[Makie.translate(x::Makie.PathCommand, v) for x in bp.commands])

## Fonts
#
# A font of the program (`FreeTypeAbstraction.FTFont`) is a face of FreeType, a pointer of the process that compiles it, which is null in the program; what the face was read from is in the font (`mmapped`, the bytes of the file,
# which are in the program as its other constants are). The face is made again from them the first time that the program reads it (as `FTFont(path)` makes it: see "Fields that are made again" in boxes.jl), with a
# library of FreeType that the program starts itself (the package's is a pointer of this process too). This is only in the program: in Julia nothing calls it, and the library is null when it is compiled.
const FTA = Makie.FreeTypeAbstraction
const FT = FTA.FreeType
const PROGRAM_FT_LIBRARY = Ref{FT.FT_Library}(C_NULL)

function program_ft_library()
    lib = PROGRAM_FT_LIBRARY[]
    if lib == C_NULL
        r = Ref{FT.FT_Library}(C_NULL)
        FT.FT_Init_FreeType(r) == 0 || error("FreeType could not be started")
        lib = r[]
        PROGRAM_FT_LIBRARY[] = lib
    end
    return lib
end

function program_face(font::FTA.FTFont)
    data = getfield(font, :mmapped)
    data === nothing && error("the font `", getfield(font, :fontname), "` was not read from a file when the program was compiled, and is not in the program")
    r = Ref{FT.FT_Face}(C_NULL)
    FT.FT_New_Memory_Face(program_ft_library(), data, length(data), Int32(0), r) == 0 || error("the font `", getfield(font, :fontname), "` could not be read")
    return r[]
end

StaticRuntime.remade_by(::Type{FTA.FTFont}, ::Val{:ft_ptr}) = program_face

end # module
