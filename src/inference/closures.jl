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
function note_function!(cl::ClosureState, @nospecialize(T))
    interesting_function_type(T) || return
    if !(T in cl.seen_functions_set)
        push!(cl.seen_functions_set, T)
        push!(cl.seen_functions, T)
    end
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
            c isa Function && (cl.box_function_seen = true)
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
# (what a module is is a fact of it, and the same in every compilation: it is kept)
const USER_MODULES = Dict{Module,Bool}()
function user_module(mod::Module)
    get!(USER_MODULES, mod) do
        root = Base.moduleroot(mod)
        (root === Base || root === Core || root === Base.Compiler || root === StaticRuntime || root === StaticTools || root === StaticCompiler) && return false
        dir = try pkgdir(root) catch; nothing end
        dir !== nothing && startswith(dir, Sys.STDLIB) && return false
        return true
    end
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

"""
    StaticRuntime.add_listeners!(x)

Say what the listeners of the observables that `x` refers to are (the ones of a `Scene` that is a constant, say), with `add_callback!`. This has a method when `Observables` is loaded.
"""
function add_listeners! end

"""
    StaticRuntime.prepare!(x)

Make `x`, an object that is made before the program is compiled and is a constant of it (a `Makie.Scene`, a `ComputeGraph`), ready for the program: what its package keeps where the types are lost is made again with the types
that it has now. The methods are in the extensions of the packages. Call it after the object is made and before compiling, and once: the object is changed.
"""
function prepare! end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(note_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) == 3
        V = callback_value_type(arginfo.argtypes[2])
        F = CC.widenconst(arginfo.argtypes[3])
        seen = compilation().closures.seen_callbacks
        if V !== nothing && F isa DataType && isconcretetype(F) && !(F <: Core.Builtin) && !((V, F) in seen)
            push!(seen, (V, F))
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
        V = callback_value_type(arginfo.argtypes[2])
        inner = copy(arginfo.argtypes[3:end])
        T = CC.widenconst(inner[1])
        fargs = arginfo.fargs === nothing ? nothing : arginfo.fargs[3:end]
        if unknown_function_type(T) && V !== nothing
            candidates = Type[F for (W, F) in c.closures.callbacks if W === V]
            # (none registered for `T`: nothing is called, as far as is known; the compilation is made again if the code that is inferred registers one)
            isempty(candidates) && return CC.Future{CC.CallMeta}(CC.CallMeta(Union{}, Union{}, CC.EFFECTS_THROWS, CC.NoCallInfo()))
            u = function_union(c, T, inner, 1; candidates)
            if u !== nothing
                c.closures.union_used = true
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
    callbacks = compilation().closures.callbacks
    if !hardlimit && sig isa DataType && isconcretetype(sig) && !isempty(callbacks)
        F = sig.parameters[1]
        any(cb -> cb[2] === F, callbacks) && return false
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
        u = isempty(c.closures.functions) ? nothing : function_union(c, T, arginfo.argtypes)
        if u !== nothing
            c.closures.union_used = true
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

# A call with keyword arguments of a function that is not known, `Core.kwcall(keywords, f, args...)`: the function is the third of the arguments
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.kwcall), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 3
        T = CC.widenconst(arginfo.argtypes[3])
        if unknown_function_type(T)
            c = compilation()
            c.closures.dispatch_requested = true
            u = isempty(c.closures.functions) ? nothing : function_union(c, T, arginfo.argtypes, 3)
            if u !== nothing
                c.closures.union_used = true
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
                    empty!(s.types)
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
        wanted = more_functions || more_callbacks || !isempty(newc) || more_boxes || slots_retry
        retry = function_passes < MAX_FUNCTION_PASSES && pass < MAX_FUNCTION_PASSES + SLOT_PASS_LIMIT + 2 && wanted
        if trace_on()
            trace("pass ", pass, ": ", round(time() - started; digits = 1), " s, ",
                  slots_retry ? "cut short by the slots (" * string(s.passes) * " of " * string(SLOT_PASS_LIMIT) * " slot passes)" : had_failure ? "failed" : "completed",
                  "; candidates ", length(cl.functions), ", found ", length(new), (more_functions ? " (adopted: " * (failure !== nothing || had_failure ? "the pass failed" : !strict ? "not strict" : cl.union_used ? "a call was made over candidates" : "a box holds a function") * ")" : " (not adopted)"),
                  "; callbacks ", length(newcb), ", boxes changed ", more_boxes, ", cfunctions ", length(newc),
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
