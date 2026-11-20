## What a pass takes from the one before
#
# The passes of a compilation (see `run_passes`) infer the program again with what the pass before found: the types of the slots, of the boxes, the functions that unknown calls are made over, the facts of the objects. Most of
# the methods of a program read none of that, or read what did not change, and what they infer is what the pass before inferred. So the code instances that a compilation makes are kept for its passes (they are of its own cache,
# `Compilation.id`, which no other compilation finds, and which `purge_inferred!` empties when it ends), and each pass takes away only those that are no longer right:
#
# * what inference of a method asks of the state of the compilation is kept with its result, with the answer (`depends!`: a question is a tuple, `(:slot, key)`, `(:universe,)`, ..., and `current_answer` answers it); a question that
#   is asked for a frame of constants, or for code that is interpreted again (`IRInterpretationState`), is the question of the method whose inference made that frame, whose result has what it found (or of the method whose code
#   is optimized, for a frame that the inliner makes);
# * at the start of a pass, a code instance is taken away when an answer is different now (`invalidate_stale!`), and so is any that has it as an edge (that called it, or has its code inlined), and so on: what is left was inferred
#   with what this pass would answer.
#
# A question that can not be given to a method (`deps_lost`: asked where no frame of inference is known) takes them all away at the next pass, as it was before. With `STATIC_RUNTIME_CACHE=1` (a cache that compilations share), the key of
# each pass is all of the state, as it was (`cache_key`), and nothing is taken away.

# (the answers to the questions about the state that is the same for a whole pass, made once when the pass starts: a number for each, made of what it is)
struct PassAnswers
    universe::UInt
    type_values::UInt
    closures::UInt
end
PassAnswers() = PassAnswers(UInt(0), UInt(0), UInt(0))

function pass_answers(c::Compilation)
    s, cl = c.slots, c.closures
    u = UInt(0)
    for t in s.universe; u += type_hash(t); end
    tv = UInt(0)
    for T in s.type_values; tv += T isa Type ? type_hash(T) : hash(T); end # (a set: the order that they were found in does not matter)
    tv = hash(s.type_slots, hash(length(s.type_values), tv))
    lt = UInt(0)
    for F in cl.listener_types; lt += type_hash(F); end
    return PassAnswers(hash(length(s.universe), u), tv, hash(closures_hash(cl), hash(cl.listeners_complete, hash(length(cl.listener_types), lt))))
end

# The answer to a question about the state of the compilation, as it is now
function current_answer(c::Compilation, q::Tuple)
    k = q[1]
    k === :slot && return slot_read_type(c, q[2])                    # what a read of a slot is given (slots.jl)
    k === :mode && return c.slots.mode                               # whether the types of the slots are used
    k === :types_empty && return isempty(c.slots.types)              # whether no slot has types
    k === :type_values && return c.answers.type_values               # the types that the slots of types hold (a call on a type that is not known is made over them)
    k === :universe && return c.answers.universe                     # the types that a call over an `Any` is made over, other than those registered
    k === :closures && return c.answers.closures                     # the functions, callbacks and listeners (closures.jl)
    k === :box && return get(c.boxes.types, q[2], nothing)           # the type of what a box holds (boxes.jl)
    o = c.objects
    k === :objready && return o.ready                                # whether the facts of the objects are there (objects.jl)
    k === :written && return written_in(o.use_written, q[2], q[3])   # whether a field is written
    k === :objfield && return field_answer(o.use_stores, o.use_unattributed, o.use_unknown, q[2], q[3]) # what is stored in a field of an object
    error("not a question about the state of a compilation: ", q)
end

# The findings of the method that a question asked in the frame `sv` is for: the method whose inference made the frame (a frame for the constants of a call, or code that is interpreted again, is part of what its caller inferred)
function deps_findings(@nospecialize(sv))
    while true
        if sv isa CC.InferenceState
            sv.result.overridden_by_const === nothing && return findings!(sv.result)
        elseif !(sv isa CC.IRInterpretationState)
            return nothing
        end
        sv = CC.frame_parent(sv)
    end
end

"""
    depends!(c::Compilation, sv, q::Tuple)

What is inferred in the frame `sv` depends on the answer to the question `q` about the state of the compilation (see `current_answer`): kept with the result of the method, so that a later pass that answers it differently infers
the method again. `sv === nothing` is a read that is not made for inference (the analysis after it), and is not kept.
"""
function depends!(c::Compilation, @nospecialize(sv), q::Tuple)
    sv === nothing && return
    c.settings.share_cache && return # (the key of the cache is all of the state)
    f = deps_findings(sv)
    if f === nothing
        # (a frame of constants whose caller is not known (an inference that is not part of the passes, `code_typed` of the check of the entry point, has frames of constants with no parent): what it found is in the results of
        # the calls of its method, which have the method as an edge. The question is the method's, kept by the compilation (`orphan_deps`), and a different answer takes away what has it as an edge)
        mi = deps_root_instance(sv)
        if mi isa Core.MethodInstance
            deps = get!(Dict{Any,Any}, c.orphan_deps, mi)
            haskey(deps, q) || (deps[q] = current_answer(c, q))
            return
        end
    end
    if f === nothing
        trace_on() && !c.deps_lost && trace("the question ", first(string(q), 200), " was asked in ", typeof(sv).name.name, sv isa CC.InferenceState ? string(" of ", sv.linfo) : "", ", which is not of a method: the next pass infers everything again")
        c.deps_lost = true
        return
    end
    deps = f.deps
    deps === nothing && (deps = f.deps = Dict{Any,Any}())
    haskey(deps, q) || (deps[q] = current_answer(c, q))
    return
end

# (the method instance of the outermost frame that `sv` is part of)
function deps_root_instance(@nospecialize(sv))
    mi = nothing
    while sv isa CC.InferenceState || sv isa CC.IRInterpretationState
        mi = sv isa CC.InferenceState ? sv.linfo : sv.mi
        sv = CC.frame_parent(sv)
    end
    return mi
end

# (the code instance of `mi` that this compilation made and that is valid, or `nothing`)
function live_instance(mi::Core.MethodInstance, @nospecialize(owner))
    isdefined(mi, :cache) || return nothing
    ci = @atomic mi.cache
    while true
        (ci.owner === owner && (@atomic ci.max_world) != 0) && return ci
        isdefined(ci, :next) || return nothing
        ci = @atomic ci.next
    end
end

"""
    invalidate_stale!(c::Compilation)

At the start of a pass: the code instances of the compilation whose answers (see `depends!`) are not those of now are taken away, with all that has one of them as an edge. The rest are what this pass infers again from the cache.
"""
function invalidate_stale!(c::Compilation)
    (c.settings.share_cache || isempty(c.inferred)) && return
    started = time()
    lost = c.deps_lost || !c.settings.reuse # (`STATIC_RUNTIME_REUSE=0`: nothing is kept)
    c.deps_lost = false
    live = IdDict{Core.MethodInstance,Core.CodeInstance}()
    owner = c.inferred[1][2]
    for (mi, o) in c.inferred
        o === owner || continue
        haskey(live, mi) && continue
        ci = live_instance(mi, owner)
        ci === nothing || (live[mi] = ci)
    end
    stale = Core.MethodInstance[]
    changed = Dict{Symbol,Int}() # (for `STATIC_RUNTIME_TRACE`: the kinds of the questions that were answered differently)
    function answered(deps)
        for (q, a) in deps
            isequal(current_answer(c, q), a) && continue
            trace_on() && (changed[q[1]] = get(changed, q[1], 0) + 1)
            return false
        end
        return true
    end
    if lost
        append!(stale, keys(live))
        empty!(c.orphan_deps)
    else
        for (mi, ci) in live
            f = findings_of(ci)
            (f === nothing || f.deps === nothing) && continue
            answered(f.deps) || push!(stale, mi)
        end
        # (the questions of methods whose frames of constants had no caller: what has the method as an edge, see `depends!`)
        for (mi, deps) in c.orphan_deps
            answered(deps) && continue
            mi in stale || push!(stale, mi)
            delete!(c.orphan_deps, mi)
        end
        direct = length(stale)
        # (what has one of them as an edge: what calls it, or has its code inlined; and what has that, and so on)
        callers = IdDict{Core.MethodInstance,Vector{Core.MethodInstance}}()
        for (mi, ci) in live, e in ci.edges
            callee = e isa Core.CodeInstance ? CC.get_ci_mi(e) : e isa Core.MethodInstance ? e : nothing
            callee isa Core.MethodInstance || continue
            push!(get!(Vector{Core.MethodInstance}, callers, callee), mi)
        end
        seen = Base.IdSet{Core.MethodInstance}(stale)
        work = copy(stale)
        while !isempty(work)
            m = pop!(work)
            for caller in get(callers, m, ())
                caller in seen && continue
                push!(seen, caller); push!(stale, caller); push!(work, caller)
            end
        end
    end
    owners = Any[owner]
    for mi in stale
        purge_owners!(mi, owners)
    end
    # (what the compilation keeps of what it made: the code instances that are left, which `purge_inferred!` takes away at the end)
    staleset = Base.IdSet{Core.MethodInstance}(stale)
    filter!(((mi, o),) -> o === owner && haskey(live, mi) && !(mi in staleset), c.inferred)
    unique!(first, c.inferred)
    trace_on() && trace("pass ", c.pass, " keeps ", length(live) - length(stale), " of ", length(live), " methods inferred before (", lost ? "all taken away: a question was asked outside of a method" :
                        string(direct, " answered differently", isempty(changed) ? "" : string(" (", join((string(k, " ", n) for (k, n) in changed), ", "), ")"), ", ", length(stale) - direct, " that depend on them"), "; ", round(time() - started; digits = 2), " s)")
    return
end
