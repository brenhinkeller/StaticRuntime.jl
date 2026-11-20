# Calls that are replaced by other calls while they are inferred: a hook returns `redirect(...)` (the call of another
# function, inferred in its place), and `optimize` writes that call into the code (`RedirectInfo`). Also the helpers for
# hooks that adjust what a call gives after it is inferred (`after_call`).

struct RedirectInfo <: CC.CallInfo
    f::Any              # the function that is called in its place
    prefix::Vector{Any} # the constants that it is given before the arguments of the call
    positions::Vector{Int} # the arguments of the call that it is given after those (`call.args[positions]`, with `call.args[1]` the function)
    info::CC.CallInfo      # what inference has of the call of `f`
end

CC.add_edges_impl(edges::Vector{Any}, info::RedirectInfo) = CC.add_edges!(edges, info.info)

# The call `f(prefix..., args[from:to]...)` in place of the call of `arginfo`, as inference has it (or of the arguments
# at `positions`, if they are given). `argtypes`, if they are given, are what the replacement is inferred with (the
# types of the arguments that it is given, which may be narrower than those of the call: the cases of a split);
# `then(result, with)`, if it is given, makes what inference has of the call of the replacement what the call gives
# (what it gives in Julia, which may be more than inference finds of the replacement: a merge of its cases).
function redirect(interp::CC.AbstractInterpreter, @nospecialize(f), prefix::Vector{Any}, from::Int, arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv::CC.AbsIntState;
                  to::Int = 0, positions = nothing, argtypes = nothing, then = nothing, with = nothing)
    positions === nothing && (positions = collect(from:(to == 0 ? length(arginfo.argtypes) : to)))
    if argtypes === nothing
        argtypes = Any[]
        for p in prefix
            push!(argtypes, CC.Const(p))
        end
        for i in positions
            push!(argtypes, arginfo.argtypes[i])
        end
    end
    call = CC.abstract_call(interp, CC.ArgInfo(nothing, Any[CC.Const(f), argtypes...]), si, vtypes, sv)
    held = Held(RedirectSpec(f, prefix, positions, then, with))
    return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
        spec = held.x::RedirectSpec
        adjusted = spec.then === nothing ? result : spec.then(result, spec.with)::CC.CallMeta
        return CC.CallMeta(adjusted.rt, adjusted.exct, adjusted.effects, RedirectInfo(spec.f, spec.prefix, spec.positions, result.info), adjusted.refinements)
    end
end

struct RedirectSpec
    f::Any
    prefix::Vector{Any}
    positions::Vector{Int}
    then::Any
    with::Any
end

# The same, decided by what Julia infers of the call: `decide(result)` gives the arguments of `redirect` (`(f, prefix,
# from)`), or `nothing` for the call as Julia has it. (Julia's call is inferred in a task of inference, and so is the
# replacement, after it: see `doworkloop` in Julia's compiler.)
function redirect_after(decide, interp::CC.AbstractInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv::CC.AbsIntState, max_methods::Int)
    result = CC.Future{CC.CallMeta}()
    state = Ref{Any}(nothing)
    stage = Ref(0)
    function step(interp, sv)
        if stage[] == 0
            state[] = julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
            stage[] = 1
        end
        if stage[] == 1
            isready(state[]) || return false
            r = decide(state[][])
            if r === nothing
                result[] = state[][]
                return true
            end
            state[] = redirect(interp, r[1], r[2], r[3], arginfo, si, vtypes, sv; positions = length(r) >= 4 ? r[4] : nothing)
            stage[] = 2
        end
        isready(state[]) || return false
        result[] = state[][]
        return true
    end
    step(interp, sv) || push!(sv.tasks, step)
    return result
end

## What a hook gives after the call that it made

# What a hook gives after the call it made: `then(result, x)`, with `x` (mostly a type) held in a field of type `Any`, so
# that the closure is one method and not one per type of `x` (a closure is specialized on what it captures).
struct Held; x::Any; end

function after_call(then, call, interp, sv, @nospecialize(x))
    h = Held(x)
    return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
        return then(result, h.x)
    end
end

result_of_type(result::CC.CallMeta, @nospecialize(T)) = result.rt === Union{} ? result : CC.CallMeta(T, result.exct, result.effects, result.info, result.refinements)

result_refined(result::CC.CallMeta, @nospecialize(T)) = CC.CallMeta(refined_read(T, result.rt), result.exct, result.effects, result.info, result.refinements)

# the type of a read that is checked (see `type_slot_get`) is the union of the types that the slot holds: what inference
# makes of the checks is a union of at most three of them, as a merge of constants is
typed_read(call, @nospecialize(T), interp, sv) = after_call(result_of_type, call, interp, sv, T)
