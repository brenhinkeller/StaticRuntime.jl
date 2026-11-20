# Calls of functions that are not known when compiling: a `Vector{Function}`, a `Dict` of functions, a closure that calls itself (the variable that it is in
# is boxed, a `Core.Box` of the type `Any`), a function in a field of an abstract type.
#
# `f(x)` where `f` is a `Function` (or an `Any`) is a call of the method that is for the type of the function that `f` is when the program runs, which is a lookup
# in the method tables of Julia: `ijl_apply_generic`. As for arguments of an abstract type (see dispatch.jl), the call is made over a union of the types that `f`
# can have, which the compiler splits in a test of the type for each. The types are those of the functions that the code that is compiled has: the closures that it
# makes, and the functions that it passes or stores (`sin` in `Function[sin, cos]`, and what is in a constant, `const FS = Function[sin, x -> 2x]`).
#
# Where that code is is not known before it is inferred, and the call is inferred before all of it is. So a compilation that has such a call, and fails (or, with
# `strict = false`, would abort at the call), is made again with the types that the first found (`run_passes`), until it finds no more.

const MAX_FUNCTION_PASSES = 8

# (What the compilation has found of this, and what the calls are made over, is in its `ClosureState`: the types of functions that were found in this pass, in the order that they were, whether it has a call of a
# function that is not known that has been looked at, and whether a call has been made over the candidates.)

# A type that a function can have that is of interest: not a function of the compiler (the types of builtins and intrinsics have no methods), and not
# something that the runtime of the program does (the functions of this package that are run when the program starts, or ends)
function interesting_function_type(@nospecialize(T))
    T isa DataType && isconcretetype(T) && T <: Function || return false
    T <: Core.Builtin && return false
    T <: Core.IntrinsicFunction && return false
    T <: Core.OpaqueClosure && return false
    mod = parentmodule(T)
    mod === Core.Compiler && return false
    mod === Base.Compiler && return false
    return true
end

function note_slow_optimization!(cl::ClosureState, mi, seconds::Float64, statements::Int)
    seconds < 0.05 && return
    # (one that takes this long is written when it is done, as the pass may not end: `STATIC_RUNTIME_TRACE=1`)
    seconds >= 5 && trace("optimizing ", mi, " took ", round(seconds; digits = 1), " s (", statements, " statements before)")
    push!(cl.slowest, (seconds, mi, statements))
    sort!(cl.slowest; by = first, rev = true)
    length(cl.slowest) > 5 && resize!(cl.slowest, 5)
    return
end
# What is found while the code of a method is inferred and optimized (the function types that it has, the callbacks and `@cfunction`s that it says, the calls of functions that are not known that it has, the boxes that it makes) is
# found only when the method is inferred. A method that is taken from the cache, where an earlier compilation inferred it, would not give it again, and what the program is compiled with would then depend on what was compiled before.
# So it is kept with the result of inference of the method (`analysis_results`, which the cache keeps with it), and the compilation takes it from all the methods that the program reaches, inferred now or not (`replay_findings!`).
mutable struct InferenceFindings
    functions::Vector{Type}
    callbacks::Vector{Tuple{Type,Type}}
    cfunctions::Vector{Tuple{DataType,Vector{DataType},DataType,Any}}
    boxes::Vector{Tuple{Core.CodeInfo,Core.MethodInstance}}   # the code of a method that makes boxes, as it was inferred (what `learn_boxes!` reads)
    dispatch_requested::Bool
    union_used::Bool
    callback_call_requested::Bool
    box_function_seen::Bool
    deps::Union{Nothing,Dict{Any,Any}}  # what inference of the method asked of the state of the compilation, with the answers (see "What a pass takes from the one before" in reuse.jl)
end
InferenceFindings() = InferenceFindings(Type[], Tuple{Type,Type}[], Tuple{DataType,Vector{DataType},DataType,Any}[], Tuple{Core.CodeInfo,Core.MethodInstance}[], false, false, false, false, nothing)

findings_of(x) = CC.traverse_analysis_results(x) do @nospecialize result
    result isa InferenceFindings ? result : nothing
end
function findings!(result::CC.InferenceResult)
    f = findings_of(result)
    f === nothing || return f
    f = InferenceFindings()
    CC.stack_analysis_result!(result, f)
    return f
end
# (the frame of inference that a call is made in: not the one of a method that is looked at again with the constants of a call, which is not what is kept)
function frame_findings(sv)
    # (a frame that is made for the constants of a call is not what is kept: what it finds is kept with the frame that made the call, whose code has it)
    while sv isa CC.InferenceState && sv.result.overridden_by_const !== nothing
        sv = CC.frame_parent(sv)
    end
    return sv isa CC.InferenceState ? findings!(sv.result) : nothing
end
function note_flag!(sv, name::Symbol)
    f = frame_findings(sv)
    f === nothing || setfield!(f, name, true)
    return
end

function replay_findings!(c::Compilation, interp, root)
    cl = c.closures
    for ci in reachable_code_instances(interp, root)
        f = findings_of(ci)
        f === nothing && continue
        for T in f.functions
            add_seen_function!(cl, T)
        end
        for x in f.callbacks
            x in cl.seen_callbacks || push!(cl.seen_callbacks, x)
        end
        for x in f.cfunctions
            any(s -> s[1] === x[1] && s[2] == x[2] && s[3] === x[3], cl.seen_cfunctions) || push!(cl.seen_cfunctions, x)
        end
        f.dispatch_requested && (cl.dispatch_requested = true)
        f.union_used && (cl.union_used = true)
        f.callback_call_requested && (cl.callback_call_requested = true)
        f.box_function_seen && (cl.box_function_seen = true)
        for (src, mi) in f.boxes
            learn_boxes!(c.boxes, src, mi)
        end
    end
    return
end

# (`T::Type`: a call with a type of the static type `Any` is dispatched on what it is, `Type{T}`, and the method is compiled for each type, in each compilation; of the static type `Type`, it is one call, compiled once)
function add_seen_function!(cl::ClosureState, @nospecialize(T))
    t = T::Type
    t in cl.seen_functions_set && return
    push!(cl.seen_functions_set, t)
    push!(cl.seen_functions, t)
    return
end

function note_function!(cl::ClosureState, @nospecialize(T))
    interesting_function_type(T) || return
    t = T::Type
    cl.sink isa InferenceFindings && !(t in cl.sink.functions) && push!(cl.sink.functions, t)
    add_seen_function!(cl, t)
    return
end

# The functions in a value that the code refers to as a constant (`FS` of `const FS = Function[sin, cos]`): in an array, a tuple, a `Dict`, the fields of a struct.
# (Not for what is large, or deep: a function in a constant of that kind is found when it is made, if it is.)
function note_functions_in!(cl::ClosureState, @nospecialize(x), depth::Int = 0, budget::Base.RefValue{Int} = Ref(2000))
    budget[] <= 0 && return
    budget[] -= 1
    if x isa Function
        note_function!(cl, typeof(x))
        # (a closure of the program that was made before it: what it took is a constant too, and a variable that it took that is assigned more than once is a `Core.Box`, whose reads are of the type `Any`)
        if fieldcount(typeof(x)) > 0 && fieldcount(typeof(x)) <= 16 && depth < 3
            for i in 1:fieldcount(typeof(x))
                isdefined(x, i) && note_functions_in!(cl, getfield(x, i), depth + 1, budget)
            end
        end
    elseif x isa Core.Box
        if isdefined(x, :contents)
            c = x.contents
            c isa Function && (cl.box_function_seen = true; cl.sink isa InferenceFindings && (cl.sink.box_function_seen = true))
            note_functions_in!(cl, c, depth + 1, budget)
        end
    elseif depth >= 3 || x isa Type || x isa Module || x isa Symbol || x isa String || x isa Number || x isa Char
        return
    elseif x isa Array || x isa Core.GenericMemory
        isbitstype(eltype(x)) && return
        for i in eachindex(x)
            isassigned(x, i) && note_functions_in!(cl, x[i], depth + 1, budget)
        end
    elseif x isa Tuple
        for e in x
            note_functions_in!(cl, e, depth + 1, budget)
        end
    elseif x isa Dict
        for (k, v) in x
            note_functions_in!(cl, k, depth + 1, budget)
            note_functions_in!(cl, v, depth + 1, budget)
        end
    elseif isstructtype(typeof(x)) && !(x isa Core.CodeInstance) && !(x isa Core.MethodInstance) && !(x isa Method) && !(x isa Core.TypeName) && fieldcount(typeof(x)) <= 16
        for i in 1:fieldcount(typeof(x))
            isdefined(x, i) && note_functions_in!(cl, getfield(x, i), depth + 1, budget)
        end
    end
    return
end

# What the statements of a method that is inferred refer to: the functions that are made (a closure is `new` of its type, which the type of the statement says), the
# functions that are values of statements, and the functions that are arguments of calls (`map(sin, xs)`, `Function[sin, cos]`: not the function that is called)
# Only the code of the program is looked at (not that of Base, or of the standard libraries, whose functions pass the functions of the program around, and are
# the ones that call them with the types that they have): a function that is stored where its type is lost is stored by the program (`Base.Fix2(+, 1)` is a call in
# it, and its type is the type of that statement)
# (what a module is is a fact of it: it is kept for the compilation. Outside of one, it is found each time)
function user_module(mod::Module)
    c = CURRENT_COMPILATION[]
    return c === nothing ? find_user_module(mod) : get!(() -> find_user_module(mod), c.user_modules, mod)
end
function find_user_module(mod::Module)
    root = Base.moduleroot(mod)
    (root === Base || root === Core || root === Base.Compiler || root === StaticRuntime || root === StaticTools || root === StaticCompiler) && return false
    dir = try pkgdir(root) catch; nothing end
    dir !== nothing && startswith(dir, Sys.STDLIB) && return false
    return true
end
function note_functions_of!(cl::ClosureState, code, types, linfo)
    def = linfo isa Core.MethodInstance ? linfo.def : nothing
    mod = def isa Method ? def.module : def isa Module ? def : nothing
    mod === nothing && return
    user_module(mod) || return
    try
        note_functions_in_code!(cl, code, types)
    catch
        # (what is found is only what the calls of unknown functions are made over: not finding is not an error)
    end
    return
end
function note_functions_in_code!(cl::ClosureState, code, types)
    for pc in eachindex(code)
        t = pc <= length(types) && isassigned(types, pc) ? types[pc] : nothing
        if t !== nothing
            if t isa Core.Const
                note_functions_in!(cl, t.val)
            else
                note_function!(cl, CC.widenconst(t))
            end
        end
        st = code[pc]
        st isa Expr || continue
        skip = st.head === :call ? 2 : st.head === :invoke ? 3 : st.head === :new ? 2 : st.head === :foreigncall ? 0 : 1
        skip == 0 && continue
        for i in skip:length(st.args)
            a = st.args[i]
            v = a isa GlobalRef ? (isdefined(a.mod, a.name) && isconst(a.mod, a.name) ? getglobal(a.mod, a.name) : nothing) :
                a isa QuoteNode ? a.value : a isa Core.SSAValue || a isa Core.Argument || a isa Expr ? nothing : a
            v === nothing && continue
            note_functions_in!(cl, v)
        end
    end
    return
end

# The types of the candidates that fit a call, as a union, or `nothing`: those that are subtypes of the type that the function is known to have, and that a method of the
# call is for (the arity, and the types of the arguments that are known: the one that has none is not a case of it)
function function_union(c::Compilation, @nospecialize(T), argtypes::Vector{Any}, position::Int = 1; candidates = c.closures.functions)
    any(a -> a isa Core.TypeofVararg, argtypes) && return nothing
    world = Base.get_world_counter()
    found = Type[]
    for C in candidates
        C <: T || continue
        sig = Tuple{(i == position ? C : CC.widenconst(a) for (i, a) in enumerate(argtypes))...}
        ms = Base._methods_by_ftype(sig, nothing, -1, world)
        ms isa Vector && !isempty(ms) || continue
        push!(found, C)
        length(found) > c.settings.split_limit && return nothing
    end
    isempty(found) && return nothing
    # (a call over one type is a call of that function, with no test that `f` is one: the type that is not callable, and that has no method, is the case that the others are tested against)
    length(found) == 1 && return Union{found[1], Nothing}
    return Union{found...}
end

## Callbacks
#
# A program that keeps functions where their types are lost (the listeners of an `Observable`, in a `Vector{Pair{Int,Any}}`) calls them with a call of a function that is not known,
# which is made over the types of all the functions that the program has (`ClosureState.functions`): `string`, `iterate` and the other functions that it passes as arguments are among them, and are
# called with whatever the value is, which may be something that they can't be compiled for. The code that stores the functions says what is stored (`note_callback(T, f)`: `f` is
# called with a value of the type `T`), and the code that calls them says that it does (`call_callback(T, f, args...)`, which is `f(args...)`), so that the call is made over
# those of the type `T`, and no others.

"""
    StaticRuntime.note_callback(T, f)

For code that is compiled with this package: say that the function `f` (the type that it has when this is inferred) may be called by a `call_callback(T, g, args...)`
of the same `T`, where the compiler does not know that `g` is `f`. Does nothing when the code runs.
"""
@noinline note_callback(@nospecialize(T), @nospecialize(f)) = nothing

"""
    StaticRuntime.call_callback(T, f, args...)

`f(args...)`, for an `f` that is one of those of `note_callback(T, f)`: when compiling with this package, the call is made over the types of those functions, and not over all those
that the program has.
"""
call_callback(@nospecialize(T), @nospecialize(f), args...) = f(args...)

"""
    StaticRuntime.add_callback!(V::Type, F::Type)

Say that there are functions of the type `F` that are called with a value of the type `V` by a `call_callback(V, f, args...)`, that were made before the program is compiled (a callback that is in a constant:
what the code of the program makes says it with `note_callback(V, f)`). Call it before compiling.
"""
add_callback!(V::Type, F::Type) = (register_callback!(V, F); nothing)

## Listeners
##
## The functions that a package keeps, to be called when something changes (the listeners of an `Observable`), are found in the constants of the program by the compilation, as it looks at them for the slots (`held_listeners`, a
## method of an extension, says which a constant holds). Each is an object that the code compares with, and calls as a constant (see "Code for each object" in objects.jl). A program reaches no listeners but those of its
## constants and those that it makes, which it says (`note_callback`), and a call of a function that is not known is made over the types of those that it makes only. What is found is the compilation's own, and nothing
## is changed: a constant that the program does not reach is not looked at, and what one compilation finds is not kept for another.

"""
    StaticRuntime.held_listeners(x)

For extensions: what `x` (an object that the constant scan of a compilation meets) holds to call, `(V, objects, types)`: the type of the value that they are called with, the listeners that the code is to compare with and call
as constants, and the types of those that are called by their type (values of bits, which hold no objects); or `nothing`. Asked only of objects of the types of `listener_holder`.
"""
held_listeners(@nospecialize(x)) = nothing
listener_holder(@nospecialize(T)) = false

# The most listeners of a type of value that a call is compared with one by one: beyond, the types of those of the type are what the calls are made over (as for `add_callback!`), and the objects are not known in them. And the
# most of all types of value, for a call where the type of value is not known (an `Observable` of an abstract type): beyond, there is no comparison, and the types of all are what such a call is made over.
const MAX_LISTENER_OBJECTS = 64
const MAX_ALL_LISTENERS = 256

# (a listener found in a constant, `f`, called with a value of the type `V`: for the whole compilation)
function note_listener!(c::Compilation, @nospecialize(V), @nospecialize(f))
    cl = c.closures
    k = (V, objectid(f))
    (k in cl.found_listener_ids && any(g -> g === f, get(cl.found_listeners, V, ()))) && return
    push!(cl.found_listener_ids, k)
    push!(get!(Vector{Any}, cl.found_listeners, V), f)
    return
end

# (whether the program says that it makes functions of the type `F`, for any type of value. A loop: see `meets_any`)
function noted_for_any(cl::ClosureState, @nospecialize(F))
    for cb in cl.callbacks
        cb[2] === F && return true
    end
    return false
end

# At the end of a pass: the listeners that the code is to compare with in the next, from all that were found; whether they are different. (A scan that was cut short may not have found all: then the types of those that were found are
# what calls are also made over, as for a type of value that has more than `MAX_LISTENER_OBJECTS`.)
function update_listeners!(c::Compilation)
    cl = c.closures
    changed = false
    truncated = c.slots.scan_truncated
    for (V, fs) in cl.found_listeners
        compared = length(fs) <= MAX_LISTENER_OBJECTS ? Tuple(fs) : ()
        if isempty(compared) || truncated
            for f in fs
                (V, typeof(f)) in cl.callbacks || (push!(cl.callbacks, (V, typeof(f))); changed = true)
            end
        end
        old = get(cl.listener_objects, V, nothing)
        if old === nothing || length(old) != length(compared) || any(i -> old[i] !== compared[i], eachindex(compared))
            cl.listener_objects[V] = compared
            changed = true
        end
    end
    empty!(cl.listener_types)
    for fs in values(cl.found_listeners), f in fs; push!(cl.listener_types, typeof(f)); end
    cl.listeners_complete = !truncated
    all = Any[]
    for fs in values(cl.listener_objects), f in fs
        any(g -> g === f, all) || push!(all, f)
    end
    all_compared = length(all) <= MAX_ALL_LISTENERS ? Tuple(all) : ()
    if length(cl.all_listeners) != length(all_compared) || any(i -> cl.all_listeners[i] !== all_compared[i], eachindex(all_compared))
        cl.all_listeners = all_compared
        changed = true
    end
    trace_on() && trace("listeners: ", sum(length, values(cl.found_listeners); init = 0), " found, of ", length(cl.listener_types), " types, for ", length(cl.found_listeners), " types of value", truncated ? " (the scan was cut short: not all)" : "", "; compared: ", sum(length, values(cl.listener_objects); init = 0))
    return changed
end

"""
    StaticRuntime.compared_listeners(V)

The listeners of the constants of the program that are called with a value of the type `V`, in a tuple (with `known_object_keys(compared_listeners, V)`, when compiling: as keys): those that a call is compared with, where the observable is not known.
"""
compared_listeners(@nospecialize(V)) = (c = CURRENT_COMPILATION[]; c === nothing ? () : get(c.closures.listener_objects, V, ()))
# (all of them, of any type of value: `known_object_keys(all_compared_listeners, nothing)`, for an observable whose type of value is not known)
all_compared_listeners(::Nothing) = (c = CURRENT_COMPILATION[]; c === nothing ? () : c.closures.all_listeners)

"""
    StaticRuntime.add_listeners!(x)

No longer needed: the listeners of the constants of a program are found when it is compiled. (It does nothing, and gives `x`.)
"""
add_listeners!(@nospecialize(x)) = x

"""
    StaticRuntime.prepare!(x)

Make `x`, an object that is made before the program is compiled and is a constant of it (a `Makie.Scene`, a `ComputeGraph`), ready for the program: what its package keeps where the types are lost is made again with the types
that it has now. The methods are in the extensions of the packages. Call it after the object is made and before compiling, and once: the object is changed.
"""
function prepare! end

"""
    StaticRuntime.typed_node(graph, key; inputs = nothing)

A node of `graph` (a `ComputePipeline.ComputeGraph`, which `prepare!` was called on, and the graphs that it is connected with) that the program reads as `node[]`, with the types of what it depends on: what the package reads to
resolve it (the edges and inputs that it comes from, and the references of their values) is of types that are not known where it is read, those of all the nodes of all the graphs. Call it before compiling, and keep it as a
constant (`const POSITIONS = StaticRuntime.typed_node(plot.attributes, :positions)`). With `inputs`, the inputs that the program changes (`typed_input`s), only what depends on them is resolved when the node is read, and only that
is compiled; a change of another input that the node depends on stops the program with an error that names it. The method is in the extension for Makie.
"""
function typed_node end

"""
    StaticRuntime.typed_input(graph, key)

An input of `graph` (see `typed_node`) that the program sets as `input[] = value`, which is what `ComputePipeline.update!(graph; key = value)` does, with what the change reaches (the graphs that depend on the input, and the listeners of
their changes) found before compiling. The value is of the type that the input has then. The method is in the extension for Makie.
"""
function typed_input end

"""
    drawing = StaticRuntime.typed_drawing(scene; inputs = (), screen_config...)

A drawing of `scene` (a `Makie.Scene`, or a `Makie.Figure`, which is made ready as saving it does: the limits of its axes are those of what they show) with CairoMakie, that the program makes as `drawing(path)` (an image of the size of the scene, written to `path` as a PNG) or `drawing(screen)` (on a
`CairoMakie.Screen` of the scene). The scene is drawn once when this is called, which adds to the graphs of its plots what drawing them needs, and they are then prepared (`prepare!`, which this calls: call it before
this, or not at all); each plot is drawn with the types that it has. Call it before compiling, after the plots are made, and keep it as a constant. `inputs` are the inputs of the plots that the program changes (`typed_input`s,
made before this): what is drawn is what the plots are when it is called, with those changes (see `typed_node`). Plots that are added afterwards are not drawn. The method is in the extension for CairoMakie.
"""
function typed_drawing end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(note_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) == 3
        V = callback_value_type(arginfo.argtypes[2])
        F = CC.widenconst(arginfo.argtypes[3])
        seen = compilation().closures.seen_callbacks
        if V !== nothing && F isa DataType && isconcretetype(F) && !(F <: Core.Builtin)
            (V, F) in seen || push!(seen, (V, F))
            f = frame_findings(sv)
            f === nothing || (V, F) in f.callbacks || push!(f.callbacks, (V, F))
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# the `T` of `Type{T}` that an argument is (a constant, or of that type), or `nothing`
function callback_value_type(@nospecialize(t))
    t isa Core.Const && return t.val isa Type ? t.val : nothing
    T = CC.widenconst(t)
    return T isa DataType && T <: Type && length(T.parameters) == 1 && T.parameters[1] isa Type ? T.parameters[1] : nothing
end

# `call_callback(T, f, args...)` is inferred as the call `f(args...)`, for the functions of the callbacks of `T` if there are some, and as for any function that is not known if not
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(call_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 3
        c = compilation()
        c.closures.callback_call_requested = true
        note_flag!(sv, :callback_call_requested)
        depends!(c, sv, (:closures,)) # (the callbacks and the listeners: see reuse.jl)
        V = callback_value_type(arginfo.argtypes[2])
        inner = copy(arginfo.argtypes[3:end])
        T = CC.widenconst(inner[1])
        fargs = arginfo.fargs === nothing ? nothing : arginfo.fargs[3:end]
        # (a function of the type of listeners of the constants: it is one of those, as the program reaches no others of the type, and makes none for `V`, as it would say (see "Listeners" above). Those that are called with a
        # value of the type `V` were compared with before, and the others are not called with one: not reached. A type of values whose listeners are too many to compare with has its types in the callbacks. Of a union of types
        # (what the slot of the listeners holds), the others)
        cl = c.closures
        uncompared(F) = !(F isa DataType && isconcretetype(F) && cl.listeners_complete && F in cl.listener_types &&
                          (V !== nothing ? !((V, F) in cl.callbacks) : (!isempty(cl.all_listeners) && !noted_for_any(cl, F))))
        if T isa Union || (T isa DataType && isconcretetype(T))
            members = Base.uniontypes(T)
            left = filter(uncompared, members)
            isempty(left) && return CC.Future{CC.CallMeta}(CC.CallMeta(Union{}, Union{}, CC.EFFECTS_THROWS, CC.NoCallInfo()))
            if length(left) < length(members)
                inner[1] = Union{left...}
                T = inner[1]
            end
        end
        if unknown_function_type(T) && V !== nothing
            candidates = Type[F for (W, F) in c.closures.callbacks if W === V]
            # (none registered for `T`: nothing is called, as far as is known; the compilation is made again if the code that is inferred registers one)
            isempty(candidates) && return CC.Future{CC.CallMeta}(CC.CallMeta(Union{}, Union{}, CC.EFFECTS_THROWS, CC.NoCallInfo()))
            u = function_union(c, T, inner, 1; candidates)
            if u !== nothing
                c.closures.union_used = true
                note_flag!(sv, :union_used)
                inner[1] = u
                call = CC.abstract_call(interp, CC.ArgInfo(fargs, inner), si, vtypes, sv)
                return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                    return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
                end
            end
        end
        return CC.abstract_call(interp, CC.ArgInfo(fargs, inner), si, vtypes, sv)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# A recursion through callbacks (a `map!`ed observable that listens to an observable and sets another one of the same type, which notifies the callbacks of its own) is not widened.
# Julia limits what it infers for a method that it is already inferring with other types (two `MapCall`s of different functions: the second is inferred as `MapCall`, with no
# parameters), and the call that is made with those types is then a dispatch over the types that the parameters could be, which a program cannot do. The callbacks are of
# finite many types (those registered), so the inference ends without the limit.
function CC.edge_matches_sv(interp::OverridesInterpreter, frame::CC.AbsIntState, method::Method, @nospecialize(sig), sparams::Core.SimpleVector,
                            hardlimit::Bool, sv::CC.AbsIntState)
    c = compilation()
    cl = c.closures
    callbacks = cl.callbacks
    if !hardlimit && sig isa DataType && isconcretetype(sig)
        depends!(c, sv, (:closures,)) # (whether the recursion is limited depends on the callbacks and listeners: see reuse.jl)
        if !(isempty(callbacks) && isempty(cl.listener_types))
            F = sig.parameters[1]
            (F in cl.listener_types || noted_for_any(cl, F)) && return false
        end
        # (code for an object, see "Code for each object" in objects.jl: as finite as the objects, from a frame for other objects; one for the same objects is limited as Julia limits it, see `object_keys`)
        has_object_key(sig) && object_keys(sig) != object_keys(CC.frame_instance(frame).specTypes) && return false
    end
    return @invoke CC.edge_matches_sv(interp::CC.AbstractInterpreter, frame::CC.AbsIntState, method::Method, sig::Any, sparams::Core.SimpleVector,
                                      hardlimit::Bool, sv::CC.AbsIntState)
end

# The type of a function that is not known: `Function`, a type of functions that has subtypes (`Base.Callable` is not one: it has types), or `Any`
function unknown_function_type(@nospecialize(T))
    T === Any && return true
    T isa DataType && !Base.isType(T) && isabstracttype(T) && T <: Function
end

# A call of `f(args...)` of an `f` that is not known (inference reaches it here, from `abstract_call`, and without this, a call of a type that has `Builtin` in it is
# a call that gives `Any`): over the types of the candidates, if there are some
function CC.abstract_call_unknown(interp::OverridesInterpreter, @nospecialize(ft), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                  vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
    T = CC.widenconst(ft)
    if unknown_function_type(T) && !(ft isa CC.PartialOpaque)
        c = compilation()
        c.closures.dispatch_requested = true
        depends!(c, sv, (:closures,)) # (the functions that it is made over: see reuse.jl)
        u = isempty(c.closures.functions) ? nothing : function_union(c, T, arginfo.argtypes)
        if u !== nothing
            c.closures.union_used = true
                note_flag!(sv, :union_used)
            argtypes = copy(arginfo.argtypes)
            argtypes[1] = u
            closed = CC.ArgInfo(arginfo.fargs, argtypes)
            call = CC.abstract_call(interp, closed, si, vtypes, sv)
            return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
            end
        end
    end
    return @invoke CC.abstract_call_unknown(interp::CC.AbstractInterpreter, ft::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                            vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# The keywords of a call that has a type as the value of one (`f(x; canvas = AsciiCanvas)`) are a constant `NamedTuple` of the type `@NamedTuple{canvas::DataType}`: a type that is a value is a `DataType` to the type of the tuple, and the method
# that has the keywords is then compiled for any type, and what it does with it (a call that is chosen by the type) is a dispatch on a type that is not known. The keywords are given the type that has the type as its one value
# (`@NamedTuple{canvas::Type{AsciiCanvas}}`), as the types of the arguments of a call that are types are: for inference (here), and as the constant that the code has (`typed_constant`, used by `optimize`).
function typed_namedtuple_type(nt::NamedTuple)
    types = Any[v isa Type ? Core.Typeof(v) : typeof(v) for v in values(nt)]
    return NamedTuple{keys(nt), Tuple{types...}}
end
has_type_values(@nospecialize(nt)) = nt isa NamedTuple && any(v -> v isa Type, values(nt))
typed_constant(nt::NamedTuple) = typed_namedtuple_type(nt)(values(nt))

function typed_keywords(interp, @nospecialize(kw))
    kw isa CC.Const && has_type_values(kw.val) || return nothing
    nt = kw.val
    return CC.PartialStruct(CC.typeinf_lattice(interp), typed_namedtuple_type(nt), Any[CC.Const(v) for v in values(nt)])
end

# `NamedTuple{names}(args)`: Base gives it the type `typeof(args)`, that of the *value* of the tuple, which for a tuple that has a value of a union of types (`Tuple{Union{UInt32,Missing}}`: the keywords of a call, the fields of `merge`) is one of the types
# that the union has, so what comes out is a `NamedTuple` of a type that is not one (`NamedTuple{(:bgcol,)}`), and what is done with it is a call of the runtime. The type of the argument is a type that it can be a value of, and the `NamedTuple` is
# given it (`NamedTuple{names,T}(args)` of Base: its fields hold what the argument holds, as a union). A call that has a constant for an argument is left to Julia, which finds the value, and so is one that has a value of the type `Any`, or of a union of many types (the candidates of one): those are split, as Julia splits them, which a `NamedTuple` that is converted to another one needs. (What is different from Julia: the type of the `NamedTuple` has the union, `@NamedTuple{a::Union{Int64,Float64}}`, where Julia's is that of the value, `@NamedTuple{a::Float64}`: `typeof` says so, and a method for the one is not one for the other. It is that, or a call of the runtime, which a program can't make.)
function CC.abstract_call_known(interp::OverridesInterpreter, f::Type{<:NamedTuple}, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) == 2 && f isa UnionAll && f.body isa DataType && f.body.name === Base.typename(NamedTuple) && f.body.parameters[1] isa Tuple
        arg = arginfo.argtypes[2]
        t = CC.widenconst(arg)
        if !(arg isa CC.Const) && t isa DataType && t <: Tuple && !Base.isvatuple(t) && !isconcretetype(t) && length(t.parameters) == length(f.body.parameters[1]) &&
           all(P -> isconcretetype(P) || P isa Core.TypeEq || (P isa Union && length(Base.uniontypes(P)) <= 4 && all(isconcretetype, Base.uniontypes(P))), t.parameters)
            full = NamedTuple{f.body.parameters[1], t}
            argtypes = Any[CC.Const(full), arg]
            return CC.abstract_call_known(interp, full, CC.ArgInfo(arginfo.fargs, argtypes), si, vtypes, sv, max_methods)
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# `host_text(f, x)` (see show.jl): the text that `f` prints for `x` in the process that compiles, made when compiling, in its world, when both are known; what the program has is the text.
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(host_text), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 3
        p, x = CC.singleton_type(argtypes[2]), CC.singleton_type(argtypes[3])
        if p !== nothing && x !== nothing
            text = try
                Base.invokelatest(host_string, p, x)
            catch
                nothing
            end
            text isa String && return CC.Future(CC.CallMeta(CC.Const(text), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# A call with keyword arguments of a function that is not known, `Core.kwcall(keywords, f, args...)`: the function is the third of the arguments
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.kwcall), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 2 && (typed = typed_keywords(interp, arginfo.argtypes[2])) !== nothing
        argtypes = copy(arginfo.argtypes)
        argtypes[2] = typed
        return CC.abstract_call_known(interp, f, CC.ArgInfo(arginfo.fargs, argtypes), si, vtypes, sv, max_methods)
    end
    if length(arginfo.argtypes) >= 3
        T = CC.widenconst(arginfo.argtypes[3])
        if unknown_function_type(T)
            c = compilation()
            c.closures.dispatch_requested = true
            note_flag!(sv, :dispatch_requested)
            depends!(c, sv, (:closures,)) # (the functions that it is made over: see reuse.jl)
            u = isempty(c.closures.functions) ? nothing : function_union(c, T, arginfo.argtypes, 3)
            if u !== nothing
                c.closures.union_used = true
                note_flag!(sv, :union_used)
                argtypes = copy(arginfo.argtypes)
                argtypes[3] = u
                closed = CC.ArgInfo(arginfo.fargs, argtypes)
                call = @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, closed::CC.ArgInfo, si::CC.StmtInfo,
                                                      vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
                return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                    return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
                end
            end
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# Compile with the types of functions that the code has: `compile(c)` is run (`c` is the compilation: see compilation.jl), and again with what it found if it has a call of an unknown function that it could not
# resolve (it failed, or it is not `strict`: such a call aborts the program), or a `@cfunction` (see cfunctions.jl), until it finds no more. The compilation is made for the call, and is not there after it.
compile_passes(compile; strict::Bool = true) = with_compilation(c -> (run_passes(c, compile), c); strict) # (what it gives, and the compilation that made it)

function run_passes(c::Compilation, compile)
    cl, bx, s = c.closures, c.boxes, c.slots
    strict = c.settings.strict
    local failure = nothing
    # (two budgets: the passes that were cut short because the types of the slots were different are counted by the slots, `SLOT_PASS_LIMIT` (the program is compiled without them when they do not settle), and the others, that
    # look for functions, callbacks and boxes, by `MAX_FUNCTION_PASSES`)
    function_passes = 0
    for pass in 1:(MAX_FUNCTION_PASSES + SLOT_PASS_LIMIT + 2)
        begin_pass!(c) # (what the last pass found is what this one is made with: see `inference_key`)
        slots_retry = false
        had_failure = false # (the pass failed, even if what follows is a pass without the slots that does not look at that)
        failure = nothing
        result = nothing
        started = time()
        try
            result = compile(c)
        catch e
            if e isa SlotsChanged
                slots_retry = true # (the types of the slots are different: see slots.jl)
            else
                (e isa UnsupportedCodeError || e isa InferenceError) || rethrow()
                failure = e
                had_failure = true
                trace_on() && trace("pass ", pass, " failed: ", first(replace(sprint(showerror, e), '\n' => ' '), 3500))
                if s.mode === :on && !isempty(s.types) && c.settings.slots_fallback && !s.fell_back
                    # (the types that the slots were given in this pass may be what failed: the first pass that has them uses what was stored that the analysis could type, and the passes that follow take back what it
                    # was wrong about; a pass that does not compile is not followed by one. The program is compiled once more without them, as it was before they were: with the failure that it has then, if it has one)
                    s.fell_back = true
                    empty!(s.types); s.type_slots = false
                    s.mode = :off
                    slots_retry = true
                    failure = nothing
                end
            end
        end
        new = Type[T for T in cl.seen_functions if !(T in cl.functions)]
        slots_retry || (function_passes += 1)
        @debug "compilation pass" pass seconds = round(time() - started; digits = 1) candidates = length(cl.functions) new = length(new) cfunctions = length(cl.cfunction_roots) failed = failure !== nothing requested = cl.dispatch_requested _id = :static_passes
        newc = [x for x in cl.seen_cfunctions if !any(r -> r.ftype === x[1] && r.args == x[2] && r.ret === x[3], cl.cfunction_roots)]
        # (a pass that was cut short, as the types of the slots are different, did not get as far as telling whether the functions that it found are needed)
        more_functions = cl.dispatch_requested && !isempty(new) && (failure !== nothing || had_failure || !strict || cl.union_used || cl.box_function_seen)
        newcb = Tuple{Type,Type}[x for x in cl.seen_callbacks if !(x in cl.callbacks)]
        more_callbacks = cl.callback_call_requested && !isempty(newcb)
        # (the types of the boxes that were found with the types that the last pass had are the ones for the next: until they are the same)
        more_boxes = any(((k, T),) -> T === Any ? haskey(bx.types, k) : get(bx.types, k, nothing) !== T, bx.seen)
        more_listeners = update_listeners!(c) # (see "Listeners" above: what the next pass compares with)
        wanted = more_functions || more_callbacks || !isempty(newc) || more_boxes || slots_retry || more_listeners
        retry = function_passes < MAX_FUNCTION_PASSES && pass < MAX_FUNCTION_PASSES + SLOT_PASS_LIMIT + 2 && wanted
        if trace_on()
            trace("pass ", pass, ": ", round(time() - started; digits = 1), " s, ",
                  slots_retry ? "cut short by the slots (" * string(s.passes) * " of " * string(SLOT_PASS_LIMIT) * " slot passes)" : had_failure ? "failed" : "completed",
                  "; candidates ", length(cl.functions), ", found ", length(new), (more_functions ? " (adopted: " * (failure !== nothing || had_failure ? "the pass failed" : !strict ? "not strict" : cl.union_used ? "a call was made over candidates" : "a box holds a function") * ")" : " (not adopted)"),
                  "; callbacks ", length(newcb), ", listeners changed ", more_listeners, ", boxes changed ", more_boxes, ", cfunctions ", length(newc),
                  "; methods optimized ", cl.optimized, " (", length(cl.optimized_unique), " different)",
                  isempty(cl.slowest) ? "" : string("; slowest to optimize: ", join((string(round(t; digits = 1), " s (", n, " statements) ", mi) for (t, mi, n) in cl.slowest), " | ")),
                  wanted ? (retry ? "; another pass" : "; no pass is left (" * string(function_passes) * " function passes)") : "; done")
        end
        if retry
            if more_boxes
                for (k, T) in bx.seen
                    T === Any ? delete!(bx.types, k) : (bx.types[k] = T)
                end
            end
            more_callbacks && append!(cl.callbacks, newcb)
            more_functions && append!(cl.functions, new)
            for x in newc
                id = length(cl.cfunction_roots) + 1
                push!(cl.cfunction_roots, Runtime.CFunctionRoot(id, x[1], x[2], x[3]))
                push!(cl.cfunction_functions, x[4])
            end
            continue
        end
        slots_retry && error("the types of the slots did not settle (", s.passes, " slot passes of ", SLOT_PASS_LIMIT, ", ", function_passes, " other passes of ", MAX_FUNCTION_PASSES, "); `STATIC_RUNTIME_TRACE=1` says what each pass found, and `STATIC_RUNTIME_SLOTS_WHY=1` which slots changed")
        failure === nothing || throw(failure)
        return result
    end
end
