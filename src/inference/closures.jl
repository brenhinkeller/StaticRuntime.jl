# Calls of functions that are not known when compiling: a function from a `Vector{Function}` or a `Dict`, a closure that
# calls itself (through a `Core.Box`), a function in a field of an abstract type.
#
# Such a call is made over a union of the function types that the program has: the closures that its code makes and the
# functions that it passes, stores, or has in its constants (`const FS = Function[sin, x -> 2x]`). They are found while
# the program is inferred, after some calls are, so a pass that finds new ones is followed by another (passes.jl).
# Callbacks (functions that a package keeps where their types are lost, the listeners of an `Observable`) and listeners
# found in the constants are handled here too.

# Whether a function type is worth a call being made over: not a builtin or intrinsic (they have no methods), and not
# one of the functions that this package's runtime calls when the program starts or ends.
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

# (`T::Type`: a call with a type of the static type `Any` is dispatched on what it is, `Type{T}`, and the method is
# compiled for each type, in each compilation; of the static type `Type`, it is one call, compiled once)
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

# The functions in a value that the code refers to as a constant (`FS` of `const FS = Function[sin, cos]`): in an array,
# a tuple, a `Dict`, the fields of a struct. (Not for what is large, or deep: a function in a constant of that kind is
# found when it is made, if it is.)
function note_functions_in!(cl::ClosureState, @nospecialize(x), depth::Int = 0, budget::Base.RefValue{Int} = Ref(2000))
    budget[] <= 0 && return
    budget[] -= 1
    if x isa Function
        note_function!(cl, typeof(x))
        # (a closure of the program that was made before it: what it took is a constant too, and a variable that it took
        # that is assigned more than once is a `Core.Box`, whose reads are of the type `Any`)
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

# The functions that a method's code refers to: closures it makes (a `new` of the closure's type), functions that are
# values of statements, and functions passed as arguments (`map(sin, xs)`, `Function[sin, cos]`; not the called function).
# Only the program's own code is looked at: Base and the standard libraries pass the program's functions around, but a
# function stored where its type is lost is stored by the program (`Base.Fix2(+, 1)` is a call in it). (Whether a module
# is the program's is cached for the compilation.)
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

# The types of the candidates that fit a call, as a union, or `nothing`: those that are subtypes of the type that the
# function is known to have, and that a method of the call is for (the arity, and the types of the arguments that are
# known: the one that has none is not a case of it)
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
    # (a call over one type is a call of that function, with no test that `f` is one: the type that is not callable, and
    # that has no method, is the case that the others are tested against)
    length(found) == 1 && return Union{found[1], Nothing}
    return Union{found...}
end

## Callbacks
#
# A program that keeps functions where their types are lost (the listeners of an `Observable`, in a
# `Vector{Pair{Int,Any}}`) calls them with an unknown call, which would be made over all of the program's functions,
# including `string`, `iterate` and others it passes around, which may not compile for the value. So the code that stores
# them says what it stores (`note_callback(T, f)`: `f` is called with a `T`), and the code that calls them says so
# (`call_callback(T, f, args...)`, which is `f(args...)`): the call is made over the callbacks of `T` only.

"""
    StaticRuntime.note_callback(T, f)

For code that is compiled with this package: say that the function `f` (the type that it has when this is inferred) may
be called by a `call_callback(T, g, args...)` of the same `T`, where the compiler does not know that `g` is `f`. Does
nothing when the code runs.
"""
@noinline note_callback(@nospecialize(T), @nospecialize(f)) = nothing

"""
    StaticRuntime.call_callback(T, f, args...)

`f(args...)`, for an `f` that is one of those of `note_callback(T, f)`: when compiling with this package, the call is
made over the types of those functions, and not over all those that the program has.
"""
call_callback(@nospecialize(T), @nospecialize(f), args...) = f(args...)

"""
    StaticRuntime.add_callback!(V::Type, F::Type)

Say that there are functions of the type `F` that are called with a value of the type `V` by a `call_callback(V, f,
args...)`, that were made before the program is compiled (a callback that is in a constant: what the code of the program
makes says it with `note_callback(V, f)`). Call it before compiling.
"""
add_callback!(V::Type, F::Type) = (register_callback!(V, F); nothing)

## Listeners
#
# The functions that a package keeps to call when something changes (the listeners of an `Observable`) are found in the
# program's constants as they are scanned for slots (`held_listeners`, a method of an extension, says which a constant
# holds). Each is compared with, and called as a constant (see object_calls.jl). A program reaches only its constants'
# listeners and those it makes, which it declares (`note_callback`), so unknown calls are made over those only. What is
# found belongs to the compilation; constants that the program does not reach are not looked at.

"""
    StaticRuntime.held_listeners(x)

For extensions: what `x` (an object that the constant scan of a compilation meets) holds to call, `(V, objects, types)`:
the type of the value that they are called with, the listeners that the code is to compare with and call as constants,
and the types of those that are called by their type (values of bits, which hold no objects); or `nothing`. Asked only
of objects of the types of `listener_holder`.
"""
held_listeners(@nospecialize(x)) = nothing
listener_holder(@nospecialize(T)) = false

# The most listeners of one value type that a call is compared with one by one (beyond, calls are made over their types,
# as for `add_callback!`), and of all value types together, for calls whose value type is not known (beyond, there is no
# comparison).
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

# At the end of a pass: the listeners that the code is to compare with in the next, from all that were found; whether
# they are different. (A scan that was cut short may not have found all: then the types of those that were found are
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

The listeners of the constants of the program that are called with a value of the type `V`, in a tuple (with
`known_object_keys(compared_listeners, V)`, when compiling: as keys): those that a call is compared with, where the
observable is not known.
"""
compared_listeners(@nospecialize(V)) = (c = CURRENT_COMPILATION[]; c === nothing ? () : get(c.closures.listener_objects, V, ()))
# (all of them, of any type of value: `known_object_keys(all_compared_listeners, nothing)`, for an observable whose type
# of value is not known)
all_compared_listeners(::Nothing) = (c = CURRENT_COMPILATION[]; c === nothing ? () : c.closures.all_listeners)

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(note_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
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
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# the `T` of `Type{T}` that an argument is (a constant, or of that type), or `nothing`
function callback_value_type(@nospecialize(t))
    t isa Core.Const && return t.val isa Type ? t.val : nothing
    T = CC.widenconst(t)
    return T isa DataType && T <: Type && length(T.parameters) == 1 && T.parameters[1] isa Type ? T.parameters[1] : nothing
end

# `call_callback(T, f, args...)` is inferred as the call `f(args...)`, for the functions of the callbacks of `T` if
# there are some, and as for any function that is not known if not
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(call_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 3
        c = compilation()
        c.closures.callback_call_requested = true
        note_flag!(sv, :callback_call_requested)
        depends!(c, sv, (:closures,)) # (the callbacks and the listeners: see passes.jl)
        V = callback_value_type(arginfo.argtypes[2])
        inner = copy(arginfo.argtypes[3:end])
        T = CC.widenconst(inner[1])
        fargs = arginfo.fargs === nothing ? nothing : arginfo.fargs[3:end]
        # (a function of a listener type of the constants is one of those, since the program reaches no others of the type
        # and makes none for `V`, as it would declare. Those called with a `V` were compared with before; the others are not
        # reached. A value type with too many listeners to compare has their types among the callbacks)
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
            # (none registered for `T`: nothing is called, as far as is known; the compilation is made again if the code
            # that is inferred registers one)
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
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# A recursion through callbacks (a `map!`ed observable that listens to one and sets another of the same type) is not
# widened. Julia limits inference of a method it is already inferring with other types (a second `MapCall` becomes
# `MapCall` without parameters), and a call with those types would dispatch. Callback types are finite (those
# registered), so inference ends without the limit.
function CC.edge_matches_sv(interp::OverridesInterpreter, frame::CC.AbsIntState, method::Method, @nospecialize(sig), sparams::Core.SimpleVector,
                            hardlimit::Bool, sv::CC.AbsIntState)
    c = compilation()
    cl = c.closures
    callbacks = cl.callbacks
    if !hardlimit && sig isa DataType && isconcretetype(sig)
        depends!(c, sv, (:closures,)) # (whether the recursion is limited depends on the callbacks and listeners: see passes.jl)
        if !(isempty(callbacks) && isempty(cl.listener_types))
            F = sig.parameters[1]
            (F in cl.listener_types || noted_for_any(cl, F)) && return false
        end
        # (code for an object, see object_calls.jl: as finite as the objects, from a frame for other objects; one for
        # the same objects is limited as Julia limits it, see `object_keys`)
        has_object_key(sig) && object_keys(sig) != object_keys(CC.frame_instance(frame).specTypes) && return false
    end
    return @invoke CC.edge_matches_sv(interp::CC.AbstractInterpreter, frame::CC.AbsIntState, method::Method, sig::Any, sparams::Core.SimpleVector,
                                      hardlimit::Bool, sv::CC.AbsIntState)
end

# The type of a function that is not known: `Function`, a type of functions that has subtypes (`Base.Callable` is not
# one: it has types), or `Any`
function unknown_function_type(@nospecialize(T))
    T === Any && return true
    T isa DataType && !Base.isType(T) && isabstracttype(T) && T <: Function
end

# A call of `f(args...)` of an `f` that is not known (inference reaches it here, from `abstract_call`, and without this,
# a call of a type that has `Builtin` in it is a call that gives `Any`): over the types of the candidates, if there are
# some
function CC.abstract_call_unknown(interp::OverridesInterpreter, @nospecialize(ft), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                  vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int)
    T = CC.widenconst(ft)
    if unknown_function_type(T) && !(ft isa CC.PartialOpaque)
        c = compilation()
        c.closures.dispatch_requested = true
        depends!(c, sv, (:closures,)) # (the functions that it is made over: see passes.jl)
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
                                            vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int)
end

# A call with keyword arguments of a function that is not known, `Core.kwcall(keywords, f, args...)`: the function is
# the third of the arguments
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.kwcall), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
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
            depends!(c, sv, (:closures,)) # (the functions that it is made over: see passes.jl)
            u = isempty(c.closures.functions) ? nothing : function_union(c, T, arginfo.argtypes, 3)
            if u !== nothing
                c.closures.union_used = true
                note_flag!(sv, :union_used)
                argtypes = copy(arginfo.argtypes)
                argtypes[3] = u
                closed = CC.ArgInfo(arginfo.fargs, argtypes)
                call = julia_call(interp, f, closed, si, vtypes, sv, max_methods)
                return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                    return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
                end
            end
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

