# The types that the program says that it has, by kind, for code whose result or callee can be of any of them. One store
# (`ClosureState.noted`, registered in `Registry.noted`, kept per method in `InferenceFindings.noted`) holds two uses of it:
#
# * a kind that is a type: the callbacks (closures.jl). The kind is the type of the value that they are called with, the types
#   are the types of the functions, and `call_callback` makes an unknown call over them;
# * a kind that is a `Symbol`: what is here, for code whose result is of any of the types, as what `deserialize` reads (a value of
#   the type that the stream says). `call_over_noted` gives them to a function that makes the result.
#
# They are found, adopted by the next pass, and invalidated the same way (see `run_passes`). What differs is when another pass is
# made over a new type (for a callback: whenever a call of a callback was inferred; for a symbol: when a `call_over_noted` of that
# kind was) and what a method that read them depends on (`:closures`, for the callbacks, with the functions and the listeners;
# `(:noted, kind)` for a symbol).
#
# The code that makes the values says so, with `note_type(kind, T)`, and the code that reads them is made over those types,
# with `call_over_noted(kind, f, args...)`, which is `f(Val{U}(), args...)` for `U`, the union of the types that were noted
# for the `kind` and those that are registered for it (`add_noted_types!`). The compiler then splits what `f` gives
# over the types of `U`, as it does for any union (so a program that reads a value of a type that is not in `U` is a
# program that stops, with the message of `f`).
#
# Nothing of this is in a program that does not use it: `note_type` is answered when it is inferred (it has no code), and a
# program that notes types, and has no `call_over_noted` of the kind, makes no other pass for them. Types that are noted
# after the `call_over_noted` that reads them is inferred are found in the pass that follows (passes.jl).

"""
    StaticRuntime.note_type(kind::Symbol, T::Type)

For code that is compiled with this package: say that the program has values of the type `T`, for the readers of the
`kind` (see `call_over_noted`). It has no code, and does nothing when it runs.
"""
@noinline note_type(@nospecialize(kind), @nospecialize(T)) = nothing

"""
    StaticRuntime.call_over_noted(kind::Symbol, f, args...)

`f(Val{U}(), args...)`, for `U` the union of the types that were noted for the `kind` (`note_type`) and registered for it
(`add_noted_types!`), when compiling with this package: `f` is a function that makes a value that can be of any of them.
(When the code runs in Julia, `U` is `Any`.)
"""
call_over_noted(kind::Symbol, f, args...) = f(Val{Any}(), args...)

"""
    StaticRuntime.add_noted_types!(kind::Symbol, types...)

Add types to those that a `call_over_noted` of the `kind` is made over, besides those that the program notes. Call it before
compiling.
"""
add_noted_types!(kind::Symbol, types::Type...) = (for T in types; register_noted!(kind, T); end; nothing)

# the types of the kind, as the union that a call is made over
noted_union(cl::ClosureState, @nospecialize(kind)) = Union{get(cl.noted, kind, Type[])...}

# what a question about the kind has as its answer (a set: the order that the types were found in does not matter)
function noted_answer(cl::ClosureState, @nospecialize(kind))
    h = UInt(0)
    for T in get(cl.noted, kind, Type[]); h += type_hash(T); end
    return hash(length(get(cl.noted, kind, Type[])), h)
end

# `note_type(kind, T)`: kept with the method that has it (it is replayed from every method that the program reaches), and
# answered with `nothing`, so that the call has no code
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(note_type), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) == 3
        k = arginfo.argtypes[2]
        kind = k isa Core.Const ? k.val : nothing
        T = callback_value_type(arginfo.argtypes[3])
        if kind isa Symbol && T !== nothing
            x = (kind, T)
            x in compilation().closures.seen_noted || push!(compilation().closures.seen_noted, x)
            fi = frame_findings(sv)
            fi === nothing || x in fi.noted || push!(fi.noted, x)
            return CC.Future(CC.CallMeta(Core.Const(nothing), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

function widen_if_nothing_noted(result::CC.CallMeta, nothing_noted)
    (nothing_noted::Bool && result.rt === Union{}) || return result
    return CC.CallMeta(Any, result.exct, result.effects, result.info, result.refinements)
end

# `call_over_noted(kind, f, args...)` is inferred as `f(Val{U}(), args...)`
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(call_over_noted), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    at = arginfo.argtypes
    if length(at) >= 3 && at[2] isa Core.Const && at[2].val isa Symbol && at[3] isa Core.Const
        kind = at[2].val::Symbol
        c = compilation()
        push!(c.closures.asked_noted, kind)
        fi = frame_findings(sv)
        fi === nothing || kind in fi.noted_asked || push!(fi.noted_asked, kind)
        depends!(c, sv, (:noted, kind))
        # (before any type is noted the reader gives nothing, and the code after it would not be looked at, where the types may
        # be noted: what it gives is then of any type, and the pass after the one that notes them is the program)
        U = noted_union(c.closures, kind)
        return redirect(interp, at[3].val, Any[Val{U}()], 4, arginfo, si, vtypes, sv; then = widen_if_nothing_noted, with = U === Union{})
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end
