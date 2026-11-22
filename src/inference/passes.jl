# The passes of a compilation. Each pass infers the program with what the passes before found (functions, callbacks and
# other noted types, `@cfunction`s, the types of boxes and slots, the facts of objects) and finds more; passes are made until what is found
# is what was used. `begin_pass!` starts a pass, `run_passes` loops, and `drive_inference!` runs the analyses after each
# inference of the program. Each pass keeps what the passes before inferred that is still right (`invalidate_stale!`,
# below).

# The most passes made for functions, callbacks and noted types, `@cfunction`s and boxes (slot passes are counted by `SLOT_PASS_LIMIT`).
const MAX_FUNCTION_PASSES = 8

# The most passes made again without the slot types that the code that failed read (see `implicated_slot_keys`), before
# a pass without any slot types.
const SLOT_NARROWINGS = 2

"""
    implicated_slot_keys(c::Compilation, e)

The slots whose types the code that `e` (an `UnsupportedCodeError`) is about was inferred with: the slot questions (see
`depends!`) of the methods of its call sites, those on the way from the entry point and those inlined at the call. A
failure of a pass with slot types gives up these slots first, rather than all of them: a program can have code that
needs the slot types (a field that holds a function, called) and code that the slot types make fail (a branch that is
reached with them).
"""
function implicated_slot_keys(c::Compilation, @nospecialize(e))
    keys = Any[]
    (e isa Runtime.UnsupportedCodeError && !isempty(c.inferred)) || return keys
    wanted = Set{Tuple{String,String,Int}}()
    for (_, sites) in e.sites, site in sites
        union!(wanted, site.methods)
    end
    isempty(wanted) && return keys
    owner = c.inferred[1][2]
    seen = Base.IdSet{Core.MethodInstance}()
    for (mi, o) in c.inferred
        (o === owner && mi.def isa Method && !(mi in seen)) || continue
        push!(seen, mi)
        m = mi.def::Method
        (String(m.name), basename(String(m.file)), Int(m.line)) in wanted || continue
        ci = live_instance(mi, owner)
        f = ci === nothing ? nothing : findings_of(ci)
        (f === nothing || f.deps === nothing) && continue
        for q in Base.keys(f.deps)
            (q isa Tuple && length(q) == 2 && q[1] === :slot && haskey(c.slots.types, q[2]) && !(q[2] in keys)) && push!(keys, q[2])
        end
    end
    return keys
end

"""
    begin_pass!(c::Compilation)

Start a pass: clear what the pass before found (each concern's `begin_pass!`), compute the pass's key and answers, and
take away the inference results that are no longer right (`invalidate_stale!`, below).
"""
function begin_pass!(c::Compilation)
    c.pass += 1
    begin_pass!(c.closures); begin_pass!(c.boxes); begin_pass!(c.slots); begin_pass!(c.dispatch); begin_pass!(c.objects)
    c.key = inference_key(c)
    c.answers = pass_answers(c)
    invalidate_stale!(c)
    return c
end

# Run `compile(c)` in a compilation of its own, in passes (see `run_passes`); gives what the last pass gave and the
# compilation, which is gone after this returns.
compile_passes(compile; strict::Bool = true) = with_compilation(c -> (run_passes(c, compile), c); strict)

# Each pass runs `compile(c)`. Another pass is made while one finds what the pass was not made with: new functions for
# unknown calls (if the pass failed, is not strict, or made a call over the candidates), callbacks and noted types, `@cfunction`s, box
# types, listeners, or different slot types (`SlotsChanged`). There are two budgets: `SLOT_PASS_LIMIT` for slot passes
# (beyond it the program is compiled without slot types) and `MAX_FUNCTION_PASSES` for the others.
function run_passes(c::Compilation, compile)
    cl, bx, s = c.closures, c.boxes, c.slots
    strict = c.settings.strict
    local failure = nothing
    function_passes = 0
    for pass in 1:(MAX_FUNCTION_PASSES + SLOT_PASS_LIMIT + 2)
        begin_pass!(c)
        slots_retry = false
        had_failure = false # (the pass failed, even if a pass without slot types follows)
        failure = nothing
        result = nothing
        started = time()
        try
            result = compile(c)
        catch e
            if e isa SlotsChanged
                slots_retry = true
            else
                (e isa UnsupportedCodeError || e isa InferenceError) || rethrow()
                failure = e
                had_failure = true
                trace_on() && trace("pass ", pass, " failed: ", first(replace(sprint(showerror, e), '\n' => ' '), 3500))
                implicated = s.mode === :on && c.settings.slots_fallback && s.narrowed < SLOT_NARROWINGS ? implicated_slot_keys(c, e) : Any[]
                if !isempty(implicated)
                    # (the slot types that the code that failed was inferred with may be what failed: give up those
                    # slots, and compile once more with the others)
                    s.narrowed += 1
                    for k in implicated
                        delete!(s.types, k); push!(s.open, k)
                    end
                    trace_on() && trace("pass ", pass, ": the slots that the code that failed read are given up (", length(implicated), "): ", first(join((string(k) for k in implicated), ", "), 1500))
                    slots_retry = true
                    failure = nothing
                elseif s.mode === :on && !isempty(s.types) && c.settings.slots_fallback && !s.fell_back
                    # (the slot types may be what failed: compile once more without them)
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
        newc = [x for x in cl.seen_cfunctions if !any(r -> r.ftype === x[1] && r.args == x[2] && r.ret === x[3], cl.cfunction_roots)]
        # (a pass cut short by the slots did not get far enough to tell whether the functions it found are needed)
        more_functions = cl.dispatch_requested && !isempty(new) && (failure !== nothing || had_failure || !strict || cl.union_used || cl.box_function_seen)
        # (types that the code says that the program has: callbacks, if a call of a callback was inferred, and those of a kind of
        # `call_over_noted` that was asked for. Another pass is made over them)
        newcb = Tuple{Any,Type}[x for x in cl.seen_noted if !(x[2] in get(cl.noted, x[1], Type[])) && (x[1] isa Symbol ? x[1] in cl.asked_noted : cl.callback_call_requested)]
        more_callbacks = !isempty(newcb)
        # (a call over the registered types that has a case that can not be compiled: that case is left out in the next pass)
        more_pruned = failure isa UnsupportedCodeError && prune_unviable!(c, failure)
        more_pruned && (failure = nothing)
        more_boxes = any(((k, T),) -> T === Any ? haskey(bx.types, k) : get(bx.types, k, nothing) !== T, bx.seen)
        more_listeners = update_listeners!(c)
        wanted = more_functions || more_callbacks || !isempty(newc) || more_boxes || slots_retry || more_listeners || more_pruned
        retry = function_passes < MAX_FUNCTION_PASSES && pass < MAX_FUNCTION_PASSES + SLOT_PASS_LIMIT + SLOT_NARROWINGS + 2 && wanted
        (trace_dispatch_on() || haskey(ENV, "STATIC_RUNTIME_CENSUS") || haskey(ENV, "STATIC_RUNTIME_CENSUS_FLOW")) && trace_census(c, pass)
        trace_on() && trace_pass(c, pass, started, slots_retry, had_failure, failure, new, more_functions, newcb, more_listeners, more_boxes, newc, wanted, retry, function_passes)
        if retry
            if more_boxes
                for (k, T) in bx.seen
                    T === Any ? delete!(bx.types, k) : (bx.types[k] = T)
                end
            end
            for (k, T) in newcb
                add_noted!(cl, k, T)
            end
            more_functions && append!(cl.functions, new)
            for x in newc
                push!(cl.cfunction_roots, Runtime.CFunctionRoot(length(cl.cfunction_roots) + 1, x[1], x[2], x[3]))
                push!(cl.cfunction_functions, x[4])
            end
            continue
        end
        slots_retry && error("the types of the slots did not settle (", s.passes, " slot passes of ", SLOT_PASS_LIMIT, ", ", function_passes, " other passes of ", MAX_FUNCTION_PASSES, "); `STATIC_RUNTIME_TRACE=1` says what each pass found, and `STATIC_RUNTIME_SLOTS_WHY=1` which slots changed")
        failure === nothing || throw(failure)
        return result
    end
end

# (for `STATIC_RUNTIME_TRACE`: what a pass found, and why another is made)
function trace_pass(c::Compilation, pass, started, slots_retry, had_failure, failure, new, more_functions, newcb, more_listeners, more_boxes, newc, wanted, retry, function_passes)
    cl, s = c.closures, c.slots
    adopted = !more_functions ? " (not adopted)" :
              string(" (adopted: ", failure !== nothing || had_failure ? "the pass failed" : !c.settings.strict ? "not strict" : cl.union_used ? "a call was made over candidates" : "a box holds a function", ")")
    slowest = isempty(cl.slowest) ? "" : string("; slowest to optimize: ", join((string(round(t; digits = 1), " s (", n, " statements) ", mi) for (t, mi, n) in cl.slowest), " | "))
    trace("pass ", pass, ": ", round(time() - started; digits = 1), " s, ",
          slots_retry ? string("cut short by the slots (", s.passes, " of ", SLOT_PASS_LIMIT, " slot passes)") : had_failure ? "failed" : "completed",
          "; candidates ", length(cl.functions), ", found ", length(new), adopted,
          "; callbacks ", length(newcb), ", listeners changed ", more_listeners, ", boxes changed ", more_boxes, ", cfunctions ", length(newc),
          "; methods optimized ", cl.optimized, " (", length(cl.optimized_unique), " different)", slowest,
          wanted ? (retry ? "; another pass" : string("; no pass is left (", function_passes, " function passes)")) : "; done")
    return
end

# After each inference of the program: replay the findings of the methods taken from the cache, and analyze the slots.
function GPUCompiler.drive_inference!(interp::OverridesInterpreter, mi::Core.MethodInstance)
    t0 = time()
    root = @invoke GPUCompiler.drive_inference!(interp::CC.AbstractInterpreter, mi::Core.MethodInstance)
    if root isa Core.CodeInstance
        c = compilation()
        t1 = time()
        replay_findings!(c, interp, root)
        t2 = time()
        try
            analyze_slots!(c, interp, root)
        finally
            trace_on() && trace("inference of ", mi.def isa Method ? mi.def.name : mi, ": ", round(t1 - t0; digits = 1), " s; findings replayed: ", round(t2 - t1; digits = 1), " s; slots analyzed: ", round(time() - t2; digits = 1), " s")
        end
    end
    return root
end

# (for the trace: the slowest methods to optimize; one over 5 s is written at once, as the pass may not end)
function note_slow_optimization!(cl::ClosureState, mi, seconds::Float64, statements::Int)
    seconds < 0.05 && return
    seconds >= 5 && trace("optimizing ", mi, " took ", round(seconds; digits = 1), " s (", statements, " statements before)")
    push!(cl.slowest, (seconds, mi, statements))
    sort!(cl.slowest; by = first, rev = true)
    length(cl.slowest) > 5 && resize!(cl.slowest, 5)
    return
end

## What a pass takes from the one before
#
# The passes of a compilation (see `run_passes`) infer the program again with what the pass before found: the types of
# the slots, of the boxes, the functions that unknown calls are made over, the facts of the objects. Most of the methods
# of a program read none of that, or read what did not change, and what they infer is what the pass before inferred. So
# the code instances that a compilation makes are kept for its passes (they are of its own cache, `Compilation.id`,
# which no other compilation finds, and which `purge_inferred!` empties when it ends), and each pass takes away only
# those that are no longer right:
#
# * what inference of a method asks of the state of the compilation is kept with its result, with the answer
#   (`depends!`: a question is a tuple, `(:slot, key)`, `(:universe,)`, ..., and `current_answer` answers it); a
#   question that is asked for a frame of constants, or for code that is interpreted again (`IRInterpretationState`), is
#   the question of the method whose inference made that frame, whose result has what it found (or of the method whose
#   code is optimized, for a frame that the inliner makes);
# * at the start of a pass, a code instance is taken away when an answer is different now (`invalidate_stale!`), and so
#   is any that has it as an edge (that called it, or has its code inlined), and so on: what is left was inferred with
#   what this pass would answer.
#
# A question that can not be given to a method (`deps_lost`: asked where no frame of inference is known) takes them all
# away at the next pass, as it was before. With `STATIC_RUNTIME_CACHE=1` (a cache that compilations share), the key of
# each pass is all of the state, as it was (`cache_key`), and nothing is taken away.

# (the answers to the questions about the state that is the same for a whole pass, made once when the pass starts: a
# number for each, made of what it is)
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
    k === :pruned && return closures_hash(c.closures)                 # the calls over the registered types that are not made over a type (dispatch.jl)
    k === :noted && return noted_answer(c.closures, q[2])            # the types that a `call_over_noted` of the kind is made over (noted.jl)
    k === :closures && return c.answers.closures                     # the functions, callbacks and listeners (closures.jl)
    k === :box && return get(c.boxes.types, q[2], nothing)           # the type of what a box holds (boxes.jl)
    o = c.objects
    k === :objready && return o.ready                                # whether the facts of the objects are there (objects.jl)
    k === :written && return written_in(o.use_written, q[2], q[3])   # whether a field is written
    k === :objfield && return field_answer(o.use_stores, o.use_unattributed, o.use_unknown, q[2], q[3]) # what is stored in a field of an object
    error("not a question about the state of a compilation: ", q)
end

# The findings of the method that a question asked in the frame `sv` is for: the method whose inference made the frame
# (a frame for the constants of a call, or code that is interpreted again, is part of what its caller inferred)
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

What is inferred in the frame `sv` depends on the answer to the question `q` about the state of the compilation (see
`current_answer`): kept with the result of the method, so that a later pass that answers it differently infers the
method again. `sv === nothing` is a read that is not made for inference (the analysis after it), and is not kept.
"""
function depends!(c::Compilation, @nospecialize(sv), q::Tuple)
    sv === nothing && return
    c.settings.share_cache && return # (the key of the cache is all of the state)
    f = deps_findings(sv)
    if f === nothing
        # (a constant frame with no known caller, from an inference outside the passes such as the entry check's `code_typed`:
        # its results live in the calls of its method, which have the method as an edge. The question is kept for the method
        # (`orphan_deps`), and a different answer takes away what has it as an edge)
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

At the start of a pass: the code instances of the compilation whose answers (see `depends!`) are not those of now are
taken away, with all that has one of them as an edge. The rest are what this pass infers again from the cache.
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
        # (the questions of methods whose frames of constants had no caller: what has the method as an edge, see
        # `depends!`)
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
    # (what the compilation keeps of what it made: the code instances that are left, which `purge_inferred!` takes away
    # at the end)
    staleset = Base.IdSet{Core.MethodInstance}(stale)
    filter!(((mi, o),) -> o === owner && haskey(live, mi) && !(mi in staleset), c.inferred)
    unique!(first, c.inferred)
    trace_on() && trace("pass ", c.pass, " keeps ", length(live) - length(stale), " of ", length(live), " methods inferred before (", lost ? "all taken away: a question was asked outside of a method" :
                        string(direct, " answered differently", isempty(changed) ? "" : string(" (", join((string(k, " ", n) for (k, n) in changed), ", "), ")"), ", ", length(stale) - direct, " that depend on them"), "; ", round(time() - started; digits = 2), " s)")
    return
end
