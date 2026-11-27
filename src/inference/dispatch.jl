# Calls on abstract types, resolved when compiling.
#
# A call whose argument has an abstract type (`area(x)` with `x::Shape`) is dispatched by the runtime
# (`ijl_apply_generic`), which a static binary does not have. Julia does resolve one kind of dynamic call itself: on an
# argument of a `Union` type it tests the type and calls the method for each member ("union splitting"). So such an
# argument is given the union of the types that it can have, and the call is inferred again with it:
#
# * an abstract type whose concrete subtypes can all be listed: those (`listed_union`);
# * `Any`, and abstract types with too many or unlisted subtypes: the registered types (`add_dispatch_candidates!`, and
#   those of `show`) and the types that the program makes (the universe, slots.jl). A value of another type is a
#   `MethodError` when the program runs, which compiling warns of.
#
# Only calls that dispatch (more than one method fits, or the one that does does not cover the argument types) are
# changed.

## The registered types:

"""
    add_dispatch_candidates!(types...)

Add concrete types to those that a call on a value of type `Any` (an element of a `Vector{Any}`, say), or of an abstract
type with too many subtypes to list (`Number`), dispatches over in compiled code. There are no types that are there to start
with: the types that the program itself makes, and the types stored in its containers of `Any`, are found without this. Use it for
a value that reaches such a call from where the compiler does not see (what a C function gives, `Base.inferencebarrier`, a global of
type `Any`): `add_dispatch_candidates!(Int, String)`. A value of a type that is not listed is an error when the program runs. 
It applies to every later compilation in the process: call it before compiling, not from a package for its own types.
"""
function add_dispatch_candidates!(types::Type...)
    for T in types
        isconcretetype(T) || throw(ArgumentError("$T is not a concrete type"))
    end
    register_types!(types)
    return nothing
end

# Types that a call is made over only when the argument is of a type that they are instances of (`Dates.DatePart{'y'}`
# for `Dates.DatePart`), and not for `Any`: they are not types that a value of `Any` is likely to have, and a call with
# two arguments of `Any` is split over the pairs of the types, which there is a limit to (`SPLIT_LIMIT`).
function add_family_candidates!(types::Type...)
    for T in types
        isconcretetype(T) || throw(ArgumentError("$T is not a concrete type"))
    end
    register_family!(types)
    return nothing
end

## The unions that an abstract type is made

# The union of the concrete subtypes of the abstract type `T`, or `nothing` if there are none, too many, or some that
# can not be listed (a subtype that is neither a concrete `DataType` nor abstract). The loaded types are the closed world
# of the program. (Cached for the compilation by type, world and limit: finding them is what takes the time.)
function listed_union(c::Compilation, @nospecialize(T))
    T isa DataType && isabstracttype(T) && T !== Any || return nothing
    # (the types of functions are not listed: there is one for each function and closure, and finding them all, which
    # `subtypes(Function)` does, takes more than a minute the first time in a process that has this package loaded. The
    # functions that a call can have are the ones of closures.jl.)
    T <: Function && return nothing
    limit = c.settings.dispatch_limit
    get!(c.closed_subtypes, (T, Base.get_world_counter(), limit)) do
        found = DataType[]
        function walk(S)
            for s in subtypes(S)
                s isa DataType || return false # (a parametric type, `UnionAll`: its instances can't be listed)
                if isabstracttype(s)
                    walk(s) || return false
                elseif isconcretetype(s)
                    push!(found, s)
                else
                    return false
                end
                length(found) <= limit || return false
            end
            return true
        end
        walk(T) && 2 <= length(found) <= limit ? Union{found...} : nothing
    end
end

# The union of the registered types that are subtypes of `T` (`Any`, or an abstract type that can't be listed), or
# `nothing`. For a call of `show`, which is also made for a `Vector{Any}` in a `Vector{Any}`, they are the types that
# `show` is registered for (see `add_dispatch_candidates!`): those of calls in general, and `Vector{Any}`.
function registered_union(c::Compilation, @nospecialize(T), show::Bool = false; universe::Bool = true)
    # (a `Union` is not looked up: `hash` of a union is the same for all unions, so a table with them for keys compares
    # each with the ones that it has, which for the unions of many types is a subtype check of each pair, and they are
    # not the types that there is a union of (the answer is quick))
    T isa Union && return nothing
    key = (T, show, universe) # (the union of a type is the same for a whole pass: what it is made of is what the compilation was at its start, and the universe, which changes between passes)
    cached = get(c.dispatch.unions, key, missing)
    cached === missing || return cached
    return c.dispatch.unions[key] = registered_union_(c, T, show, universe)
end
# (whether `registered_union(c, T, show)` reads the universe: the types that the program makes, which change between
# passes)
reads_universe(c::Compilation, @nospecialize(T), show::Bool) = c.settings.universe && T isa Type && !(T <: Type) && (T === Any || isabstracttype(Base.unwrap_unionall(T)) || T isa UnionAll)

# the exceptions of Base that a program is likely to catch and show (when it throws them: see `note_thrown!`)
const COMMON_EXCEPTIONS = Set{Any}([ErrorException, ArgumentError, OverflowError, AssertionError, EOFError, DivideError, StringIndexError])

# the functions that a caught exception is given to to say what it is (and not those that keep it, as the constructor of an exception that has it
# in a field, or `rethrow`, which a call over the types that it can be would only make more of)
const EXCEPTION_SHOWERS = Any[Base.showerror, Base.show, Base.print, Base.println, Base.string, Base.repr, Base.sprint]
function shows_exception(arginfo::CC.ArgInfo)
    f = CC.singleton_type(arginfo.argtypes[1])
    f === nothing && return false
    f === Core.kwcall && length(arginfo.argtypes) >= 4 && (f = CC.singleton_type(arginfo.argtypes[3])) # (`sprint(f, e; context = ...)`)
    return f !== nothing && any(g -> g === f, EXCEPTION_SHOWERS)
end

# the registered types that are subtypes of `T` (`Any`)
function registered_types(c::Compilation, @nospecialize(T), show::Bool)
    candidates = show ? c.registered.show : c.registered.dispatch
    return Type[C for C in candidates if C <: T]
end

function registered_union_(c::Compilation, @nospecialize(T), show::Bool, universe::Bool)
    # (a `UnionAll` that is not abstract is a type that has parameters that are not known, `Dates.DatePart`: its
    # instances are of the types of it that were registered)
    T isa Type && !(T <: Type) && (T === Any || isabstracttype(Base.unwrap_unionall(T)) || T isa UnionAll) || return nothing # (`Type{X}` is not an abstract type of objects)
    candidates = show ? c.registered.show : c.registered.dispatch
    T === Any || (candidates = vcat(candidates, c.registered.family))
    found = Type[C for C in candidates if C <: T]
    if universe && c.settings.universe
        # (the types that the program makes, that are not Julia's own: see slots.jl. How many there are is the limit
        # that the call is split in, once the methods are looked at (`close_abstract_arguments`))
        for t in universe_extras(c, T)
            t in found || push!(found, t)
        end
        return isempty(found) ? nothing : Union{found...}
    end
    1 <= length(found) <= c.settings.split_limit || return nothing
    return Union{found...}
end

# (The calls that were made over the registered types, for the warning: function, and the types of its arguments:
# `DispatchState.registered_calls`.)

# The arguments of a call with the abstract types made unions, and the `Tuple` of their types (that of the function
# comes first, and is not changed), or `nothing` if there is none to change; and whether one of them was made of the
# registered types
function close_abstract_arguments(c::Compilation, interp, arginfo::CC.ArgInfo, max_methods::Int, @nospecialize(sv) = nothing)
    argtypes = copy(arginfo.argtypes)
    changed = false
    registered = false
    isshow = CC.widenconst(argtypes[1]) === typeof(show)
    for i in 2:length(argtypes)
        argtypes[i] isa Core.TypeofVararg && continue # (a call with the arguments that are the rest of a splat: not known)
        T = CC.widenconst(argtypes[i]) # (a constant is of a concrete type; the rest of what is known of an argument is lost)
        # (a type that is not known (`Type`, `DataType`) in a program with slots of types: one of the types they hold, read
        # through something that loses its type, such as a tuple returned by `iterate`. The call is made over them; another type
        # is a `MethodError`)
        if (T === DataType || T === UnionAll || type_value_slot(T)) && (depends!(c, sv, (:type_values,)); c.slots.type_slots) # (see passes.jl)
            u = type_values_union(c, T)
            if u !== nothing
                argtypes[i] = with_methods(c, interp, arginfo, i, u, max_methods)
                registered = true
                changed = true
                continue
            end
        end
        u = listed_union(c, T)
        reg = false
        if u === nothing && T === Any && shows_exception(arginfo) && is_caught_exception(c, arginfo, i, sv)
            # (`catch e`: the registered types, the exceptions of the program's own that it makes, and the exceptions of Base that are
            # commonly caught, for those of them that the code throws. Not all of the exceptions that it throws: a call that is split over
            # more than a few dozen is not one that inference can do.)
            c.slots.catch_seen = true
            depends!(c, sv, (:universe,))
            found = Any[t for t in registered_types(c, T, isshow)]
            for t in universe_extras(c, Exception)
                t in found || push!(found, t)
            end
            for t in thrown_extras(c, Exception)
                (t in COMMON_EXCEPTIONS || user_relevant(t)) && !(t in found) && push!(found, t)
            end
            if !isempty(found) && length(found) <= c.settings.split_limit
                note_dispatch_used!(c, sv)
                u = Union{found...}
                reg = true
                depends!(c, sv, (:pruned,))
                u = without_pruned(c, arginfo, u)
                u === nothing && continue
                u = with_methods(c, interp, arginfo, i, u, max_methods)
                    registered |= reg
                argtypes[i] = u
                changed = true
                continue
            end
        end
        if u === nothing
            reads_universe(c, T, isshow) && depends!(c, sv, (:universe,)) # (see passes.jl)
            u = registered_union(c, T, isshow)
            u === nothing && continue
            reg = true
            depends!(c, sv, (:pruned,)) # (the types that the call is not made over: see `prune_unviable!`)
            u = without_pruned(c, arginfo, u)
            u === nothing && continue
            # (only the types that some method fits are kept: the others are `MethodError`s whatever the program does,
            # and each of them counts for the limit on the number of cases that a call is split in)
            u = with_methods(c, interp, arginfo, i, u, max_methods)
            if Base.unionlen(u) > c.settings.split_limit
                # (too many with the types that the program makes: the registered ones only, as without them)
                u = registered_union(c, T, isshow; universe = false)
                u === nothing && continue
                u = without_pruned(c, arginfo, u)
                u === nothing && continue
                u = with_methods(c, interp, arginfo, i, u, max_methods)
            end
        else
            u = with_methods(c, interp, arginfo, i, u, max_methods)
        end
        registered |= reg
        argtypes[i] = u
        changed = true
    end
    changed || return nothing
    return CC.ArgInfo(arginfo.fargs, argtypes), CC.argtypes_to_type(argtypes), registered
end

# The members of the union `u` (what argument `i` can be) that some method fits, with the other arguments as they are
# (their widest: a member no method fits then fits none for their narrower cases). A union with none is left to Julia;
# `u` itself if every member fits, a single type if one does. The function's methods are looked up once (not filtered
# beyond `METHOD_FILTER_LIMIT` methods), and a member fits a method if their types intersect, as Julia matches methods,
# without a lookup for each member (which cost more than it saved).
const METHOD_FILTER_LIMIT = 64

function method_signatures(c::Compilation, interp, @nospecialize(ft), n::Int)
    world = CC.get_inference_world(interp)
    return get!(c.dispatch.signatures, (world, ft, n)) do
        found = CC.findall(Tuple{ft, Vararg{Any,n}}, CC.method_table(interp); limit = METHOD_FILTER_LIMIT)
        found === nothing || length(found.matches) > METHOD_FILTER_LIMIT ? nothing : Any[m.method.sig for m in found.matches]
    end
end

# (a call that has a splat of a length that is not known: the signatures of the methods are looked up for a number of
# arguments, which is not the number that it has: the methods that have another number are not the ones that it can not
# be, and the types that only they fit would be left out)
has_unknown_length(arginfo::CC.ArgInfo) = any(a -> a isa Core.TypeofVararg, arginfo.argtypes)

function with_methods(c::Compilation, interp, arginfo::CC.ArgInfo, i::Int, u, max_methods::Int)
    (c.settings.filter_by_methods && Base.unionlen(u) > 1 && !has_unknown_length(arginfo)) || return u
    ft = CC.widenconst(arginfo.argtypes[1])
    sigs = method_signatures(c, interp, ft, length(arginfo.argtypes) - 1)
    (sigs === nothing || isempty(sigs)) && return u
    others = Any[a isa Core.TypeofVararg ? Any : CC.widenconst(a) for a in arginfo.argtypes]
    kept = Any[]
    members = Base.uniontypes(u)
    for M in members
        others[i] = M
        atype = Tuple{others...}
        meets_any(atype, sigs) && push!(kept, M)
    end
    (isempty(kept) || length(kept) == length(members)) && return u
    return Union{kept...}
end

# Whether the call dispatches on its argument types: more than one method fits, too many to count, or the one that fits
# does not cover the arguments. (Julia resolves a call of a few methods by testing their signature types and calls the
# method with the argument as that type: for an unlisted abstract type that dispatches again inside. So the types of the
# objects are tested here, and an unknown type is an error.)
function dispatch_needed(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    # (an argument of a type that has parameters that are not known (`Dates.DatePart`, a parametric struct that
    # inference has merged the instances of) is an object of one of the registered types of it, whatever the one method
    # is that fits all of them)
    for i in 2:length(arginfo.argtypes)
        arginfo.argtypes[i] isa Core.TypeofVararg && continue
        T = CC.widenconst(arginfo.argtypes[i])
        T isa UnionAll && !(T <: Type) && return true
    end
    matches = method_matches(interp, arginfo, atype, max_methods)
    matches isa CC.FailedMethodMatch && return true
    return length(matches.applicable) > 1 || !CC.fully_covering(matches)
end

# the methods that fit a call (what Julia's inference finds them with), or `FailedMethodMatch` if there are too many to
# count
method_matches(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int) = arginfo.fargs === nothing ?
    CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods) :
    CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods, fargs = arginfo.fargs)

# whether some method fits a call with these argument types: by the signatures of the methods of the function (looked up
# once: see `method_signatures`) when it has few, and else as inference finds them
function some_method_fits(c::Compilation, interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    sigs = c.settings.filter_by_methods && !has_unknown_length(arginfo) ? method_signatures(c, interp, CC.widenconst(arginfo.argtypes[1]), length(arginfo.argtypes) - 1) : nothing
    sigs === nothing || return meets_any(atype, sigs)
    matches = method_matches(interp, arginfo, atype, max_methods)
    return matches isa CC.FailedMethodMatch || !isempty(matches.applicable) # (too many to count: some fit)
end

# For calls over the registered types: the matches are marked as not covering the argument types (`fully_covers`, which
# Julia's union splitting looks at), so the call tests every type instead of all but the last; anything left over is a
# `MethodError`, since `Any` can be more than the registered types.
function uncovered(info::CC.MethodMatchInfo)
    matches = Core.MethodMatch[Core.MethodMatch(m.spec_types, m.sparams, m.method, false) for m in info.results.matches]
    results = CC.MethodLookupResult(matches, info.results.valid_worlds, info.results.ambig)
    new = CC.MethodMatchInfo(results, info.mt, info.atype, false)
    copyto!(new.edges, info.edges)
    copyto!(new.needs_mi_edges, info.needs_mi_edges)
    copyto!(new.call_results, info.call_results)
    return new
end
function uncovered(info::CC.UnionSplitInfo)
    split = copy(info.split)
    split[end] = uncovered(split[end])
    return CC.UnionSplitInfo(split)
end
uncovered(info) = info

function CC.abstract_call_gf_by_type(interp::OverridesInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                     @nospecialize(atype), vtypes::VTypes,
                                     sv::Union{CC.IRInterpretationState{I},CC.InferenceState{I}} where I<:CC.AbstractInterpreter,
                                     max_methods::Int)
    c = compilation()
    if sv isa CC.InferenceState
        # (a function that the target does not have, replaced by one of Julia's: see `TARGET_REPLACEMENTS`)
        replacement = target_replacement(f)
        replacement === nothing || return redirect(interp, replacement, Any[], 2, arginfo, si, vtypes, sv)
        # (a call with keywords is `Core.kwcall(keywords, f, args...)`: the same, with the function that is called replaced)
        if f === Core.kwcall && length(arginfo.argtypes) >= 3
            called = CC.singleton_type(arginfo.argtypes[3])
            replacement = called === nothing ? nothing : target_replacement(called)
            replacement === nothing || return redirect(interp, kwcall_with, Any[replacement], 2, arginfo, si, vtypes, sv; positions = Int[2; 4:length(arginfo.argtypes)])
        end
    end
    # (a call that is made for an object that is a constant: code of its own for the object, see "Any function, for each
    # object" in object_calls.jl)
    if sv isa CC.InferenceState
        plan = object_call_plan(c, interp, f, arginfo)
        plan === nothing || return redirect(interp, plan[1], plan[2], 0, arginfo, si, vtypes, sv; positions = plan[3])
    end
    registered = false
    slot_argtypes = arginfo.argtypes # (what the arguments were before they were closed: see below)
    closed = close_abstract_arguments(c, interp, arginfo, max_methods, sv)
    # (a call that none of the types that the arguments are closed to has a method for is left as it is: it is not known
    # what the arguments are, and the result of the call is not that it is an error, which would make what calls it one
    # too)
    closed === nothing || some_method_fits(c, interp, closed[1], closed[2], max_methods) || (closed = nothing)
    if closed !== nothing && dispatch_needed(interp, arginfo, atype, max_methods)
        original = arginfo.argtypes
        arginfo, atype, registered = closed
        note_dispatch_split!(f, original, arginfo.argtypes, registered)
        max_methods = max(max_methods, c.settings.split_limit) # (one method for each type, at most)
        if registered
            fname = f isa Function ? nameof(f) : f isa Type ? f : nameof(typeof(f))
            # (the function and the types: made into text only for the message, as this is each call that is made over
            # them)
            key = (fname, Any[T isa Core.TypeofVararg ? T : CC.widenconst(T) for T in original[2:end]])
            calls = c.dispatch.registered_calls
            calls[key] = get(calls, key, 0) + 1
            note_cases!(c, sv, original, arginfo)
            (trace_dispatch_on() || haskey(ENV, "STATIC_RUNTIME_CENSUS") || haskey(ENV, "STATIC_RUNTIME_CENSUS_FLOW")) && note_census!(c, sv, original, arginfo)
            note_dispatch_used!(c, sv)
        end
    end
    # (an argument of an abstract type: slot types may make it narrower (slots.jl). The types are those before closing to
    # listed subtypes: `LinkedList{Int}` closed to `Cons{Int}` would read fields from what may be a `Nil`, which only slot
    # types rule out)
    if !registered && !c.dispatch.registered_used && c.slots.mode !== :off
        for T in slot_argtypes[2:end]
            T isa Core.TypeofVararg && continue
            T = CC.widenconst(T)
            # (a struct of the program with parameters that are not known, `Input` of `Input{T}`, is what is read from a
            # slot that is declared so: what the slots hold is its instances. Not Julia's own, a `Vector` or a `Dict` of
            # some type: most programs have those, and would be analyzed for them)
            if (((T isa DataType && isabstracttype(T)) || unknown_parameters_of_program(T)) && !(T <: Function) && !(T <: Type)) || type_value_slot(T)
                # (a type as a value that is not known, `Type`: it is what is read from a slot of types, see slots.jl)
                note_dispatch_used!(c, sv)
                break
            end
        end
    end
    # (a call on one of a few types is split in those cases, but Julia does not follow a call with more than `max_methods`
    # methods, as functions of types can have; only in programs with slots of types, since unions of a few types are common in
    # Base, `convert(::Union{Type{Bool},Type{Int}}, x)`)
    if any(a -> !(a isa Core.TypeofVararg) && (T = CC.widenconst(a); T isa Union && all(exact_type_value, Base.uniontypes(T))), arginfo.argtypes[2:end]) &&
       (depends!(c, sv, (:type_values,)); c.slots.type_slots) # (see passes.jl)
        max_methods = max(max_methods, c.settings.split_limit)
    end
    call = @invoke CC.abstract_call_gf_by_type(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo, atype::Any,
                    vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int)
    registered || return call
    return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
        return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
    end
end

## `show` of an element whose types are known

# `show_element(io, x, T)` shows an element that is declared to be of the type `T` (`Any`, for the elements of a `Vector{Any}` or a
# field), which is made over the registered types. But the element has the types that inference found for it (the slots of
# containers of abstract elements, when slots.jl knows what is in them): a concrete type, or a few. When that is so the call is
# `show(io, x)`, made over them, and the registered types are not asked. Each is a case of a call (`note_cases!`), so one whose
# code can not be compiled is left out (`prune_unviable!`), and then the element is shown over the registered types, as it was.
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(show_element), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    at = arginfo.argtypes
    if length(at) == 4
        T = callback_value_type(at[4])
        X = CC.widenconst(at[3])
        members = Base.uniontypes(X)
        if T !== nothing && !isconcretetype(T) && !isempty(members) && all(m -> m isa DataType && isconcretetype(m), members)
            c = compilation()
            depends!(c, sv, (:pruned,)) # (the types that the call is not made over: see `prune_unviable!`)
            pruned = get(c.closures.pruned, :show, nothing)
            if pruned === nothing || !any(m -> m in pruned, members)
                fi = frame_findings(sv)
                for m in members
                    push!(c.dispatch.cases, (:show, m))
                    fi === nothing || (:show, m) in fi.cases || push!(fi.cases, (:show, m))
                end
                return redirect(interp, show, Any[], 2, arginfo, si, vtypes, sv; positions = [2, 3], argtypes = Any[at[2], X],
                                then = (result, _) -> CC.CallMeta(Nothing, result.exct, result.effects, result.info, result.refinements))
            end
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

## Calls over the registered types that can not be compiled
#
# A call on an `Any` is made over the registered types and the universe, which is more than what the values can be: a type that
# no value of reaches the call has code that is compiled for it all the same, and for some types (a struct that has a closure in
# a field, a `Module`) that code can not be compiled. That is not an error of the program: the value is never of that type.
# So when the code of a call over the registered types can not be compiled (the strict check says where, with the way from the
# entry point), the type is left out of that call, as the registered types that are not are: it is a `MethodError` if a value
# of it reaches the call, and compiling says so. The next pass is made without it. (`pruned` is of the compilation; the cases
# of each call, kept with the code of the method that makes it, are what a failure is attributed to.)

# the name of the function of a call, as the functions of the code that is compiled have it (`show`, `print`); `:unknown` for
# one that has no name that the code is known by
function callee_symbol(@nospecialize(ft))
    ft = CC.widenconst(ft)
    if ft isa DataType
        isdefined(ft, :instance) && ft.instance isa Function && return nameof(ft.instance)
        ft <: Type && length(ft.parameters) == 1 && ft.parameters[1] isa DataType && return nameof(ft.parameters[1])
    end
    return :unknown
end

# the members of `u` that the call is made over: those that were not left out of it
function without_pruned(c::Compilation, arginfo::CC.ArgInfo, @nospecialize(u))
    isempty(c.closures.pruned) && return u
    list = get(c.closures.pruned, callee_symbol(arginfo.argtypes[1]), nothing)
    list === nothing && return u
    kept = Any[M for M in Base.uniontypes(u) if !(M in list)]
    isempty(kept) && return nothing
    return Union{kept...}
end

# the types that the arguments of the call were closed to, for each function that is called: what a failure is attributed to
function note_cases!(c::Compilation, @nospecialize(sv), original, closed::CC.ArgInfo)
    name = callee_symbol(closed.argtypes[1])
    name === :unknown && return
    fi = frame_findings(sv)
    for i in 2:length(original)
        original[i] isa Core.TypeofVararg && continue
        CC.widenconst(original[i]) === CC.widenconst(closed.argtypes[i]) && continue
        for M in Base.uniontypes(CC.widenconst(closed.argtypes[i]))
            push!(c.dispatch.cases, (name, M))
            fi === nothing || (name, M) in fi.cases || push!(fi.cases, (name, M))
        end
    end
    return
end

# The methods (as `(name, file, line)` of their definitions: what the strict check has for the places that it names) that
# the code of `mi` reaches, through the methods that it calls and those that were inlined in it
function reached_methods(c::Compilation, mi::Core.MethodInstance, owner, cache::IdDict{Core.MethodInstance,Set{Tuple{String,String,Int}}})
    haskey(cache, mi) && return cache[mi]
    found = Set{Tuple{String,String,Int}}()
    seen = Base.IdSet{Core.MethodInstance}()
    stack = Core.MethodInstance[mi]
    while !isempty(stack)
        m = pop!(stack)
        m in seen && continue
        push!(seen, m)
        if m.def isa Method
            push!(found, (String(m.def.name), basename(String(m.def.file)), Int(m.def.line)))
        end
        ci = live_instance(m, owner)
        ci === nothing && continue
        for e in ci.edges
            callee = e isa Core.CodeInstance ? CC.get_ci_mi(e) : e isa Core.MethodInstance ? e : nothing
            callee isa Core.MethodInstance && push!(stack, callee)
        end
    end
    return cache[mi] = found
end

# A call over the registered types whose code can not be compiled, from the strict check that said so (`e`): for each place that
# it names, the cases of the calls over the registered types (the function, and a type that it was made over) whose code reaches
# the method that has the place, are left out. A case is attributed to a place by what its code reaches, since the compiled
# functions do not say what type they are for. Whether any was left out: another pass is made.
function prune_unviable!(c::Compilation, e)
    e isa UnsupportedCodeError || return false
    isempty(c.dispatch.cases) && return false
    isempty(c.inferred) && return false
    owner = c.inferred[1][2]
    # (what each specialization of a function of a case, for the type of the case, reaches)
    by_name = Dict{Symbol,Vector{Core.MethodInstance}}()
    for (mi, o) in c.inferred
        (o === owner && mi.def isa Method) || continue
        push!(get!(Vector{Core.MethodInstance}, by_name, mi.def.name), mi)
    end
    cache = IdDict{Core.MethodInstance,Set{Tuple{String,String,Int}}}()
    added = false
    for (_, sites) in e.sites, site in sites
        isempty(site.methods) && continue
        failing = site.methods[1] # (the method that has the call, from the debug information of the call: the innermost)
        for (name, M) in c.dispatch.cases
            list = get(c.closures.pruned, name, nothing)
            list !== nothing && M in list && continue
            # (a type that was registered is one that the user said values of are there: it is not left out for what other types
            # need. A place in a function that every case reaches (`print`, `getindex`) is the same for all of them, and the code of
            # the case that does not compile is not told apart from the others that reach it by the functions, only by what they do)
            (M in c.registered.dispatch || M in c.registered.show) && continue
            implicated = false
            for mi in get(by_name, name, Core.MethodInstance[])
                sig = Base.unwrap_unionall(mi.specTypes)
                sig isa DataType && any(p -> p === M, sig.parameters) || continue
                failing in reached_methods(c, mi, owner, cache) && (implicated = true; break)
            end
            implicated || continue
            push!(get!(Vector{Any}, c.closures.pruned, name), M)
            added = true
            message = string("a call of `", name, "` over the registered types and the universe is not made over `", M,
                             "`: the code for it can not be compiled (", site.function_name, " in `", failing[1], "`, ", failing[2], ":", failing[3], "). A value of that type that reaches the call is a `MethodError`.")
            # (a type of Julia's own that the program found for itself (a `Vector{TypeVar}` that something of Base holds) is one that the
            # program has no value of that the user could say: a warning is for a type that the user made or registered)
            if user_relevant(M) || M in c.registered.dispatch || M in c.registered.show
                compile_warning!((:unviable, name, M), message)
            else
                @debug message _id = :static_pruned
            end
        end
    end
    return added
end

## Where the values of a call over the registered types come from (trace `dispatch`)
#
# For each argument that was closed to a union of the registered types and the universe: what defines the value in the code
# of the method that makes the call (an argument of the method, a call of a function, a read of a field or of a slot, a phi),
# and how many types it was made over. This is what a flow of types that was found for each call would replace those with
# (see "Principled candidates" in the notes): the census says which kinds of origins there are and how large the sets are.

function code_statements(@nospecialize(sv))
    sv isa CC.InferenceState && return sv.src.code
    sv isa CC.IRInterpretationState && return Any[sv.ir.stmts[i][:stmt] for i in 1:length(sv.ir.stmts)]
    return nothing
end

# what a call is called, for the census
function callee_name(@nospecialize(g))
    g isa GlobalRef && return string(g.name)
    g isa Core.MethodInstance && return string(g.def isa Method ? g.def.name : g)
    g isa Core.SSAValue || g isa Core.Argument || g isa Core.SlotNumber && return "a function that is a value"
    return g isa Function ? string(nameof(g)) : string(g)
end

const CENSUS_READS = ("getfield", "memoryrefget", "getindex", "unsafe_load", "memoryref", "arrayref")

# where the value `x` of the code of `sv` comes from: described by what defines it, followed through a pi, a copy and a
# variable that is assigned once, a few steps
function value_origin(@nospecialize(sv), @nospecialize(x), depth::Int = 0)
    x isa Core.Argument && return string("argument ", x.n - 1, " of the method")
    x isa Core.SSAValue || x isa Core.SlotNumber || return x isa GlobalRef ? string("the global ", x.name) : "a constant"
    code = code_statements(sv)
    code === nothing && return "code that is not at hand"
    if x isa Core.SlotNumber
        nargs = sv isa CC.InferenceState ? Int(sv.src.nargs) : 0
        defs = Any[st.args[2] for st in code if st isa Expr && st.head === :(=) && st.args[1] == x]
        isempty(defs) && return x.id <= nargs ? string("argument ", x.id - 1, " of the method") : "a variable with no assignment"
        length(defs) == 1 && depth < 3 && return value_origin(sv, defs[1], depth + 1)
        return string("a variable assigned in ", length(defs), " places")
    end
    stmt = x.id <= length(code) ? code[x.id] : nothing
    stmt === nothing && return "code that is not at hand"
    stmt isa Core.PhiNode && return "a phi"
    stmt isa Core.PiNode && return depth < 3 ? value_origin(sv, stmt.val, depth + 1) : "a pi"
    stmt isa Core.SSAValue || stmt isa Core.SlotNumber || stmt isa Core.Argument ? (return depth < 3 ? value_origin(sv, stmt, depth + 1) : "a copy") : nothing
    if stmt isa Expr
        if stmt.head === :call || stmt.head === :invoke
            name = callee_name(stmt.args[1])
            name in CENSUS_READS && return string("a read (", name, ")")
            name == "typeassert" && depth < 3 && return value_origin(sv, stmt.args[2], depth + 1)
            return string("the result of `", name, "`")
        end
        stmt.head === :static_parameter && return "a type parameter"
        stmt.head === :new && return "an object that is made here"
        return string("`", stmt.head, "`")
    end
    return stmt isa QuoteNode ? "a constant" : string(typeof(stmt))
end

# the methods that are being inferred, from the one that makes the call outwards (for the census: who reached it)
function census_chain(@nospecialize(sv))
    names = String[]
    while sv isa CC.InferenceState || sv isa CC.IRInterpretationState
        mi = sv isa CC.InferenceState ? sv.linfo : sv.mi
        push!(names, mi isa Core.MethodInstance && mi.def isa Method ? string(mi.def.name) : string(mi))
        length(names) >= 12 && break
        sv = CC.frame_parent(sv)
    end
    return join(names, " < ")
end

function note_census!(c::Compilation, @nospecialize(sv), original, closed::CC.ArgInfo)
    fargs = closed.fargs
    caller = sv isa CC.InferenceState ? sv.linfo : sv isa CC.IRInterpretationState ? sv.mi : nothing
    f = closed.argtypes[1]
    callee = CC.widenconst(f)
    callee = callee isa DataType && isdefined(callee, :instance) ? nameof(callee.instance) : callee
    for i in 2:length(original)
        original[i] isa Core.TypeofVararg && continue
        T0 = CC.widenconst(original[i])
        T1 = CC.widenconst(closed.argtypes[i])
        T0 === T1 && continue
        origin = fargs === nothing || i > length(fargs) ? "not known" : value_origin(sv, fargs[i])
        param = fargs === nothing || i > length(fargs) || caller === nothing ? nothing : argument_param(sv, fargs[i])
        push!(c.dispatch.census, (caller = caller, callee = callee, arg = i - 1, from = T0, ncand = Base.unionlen(T1), origin = origin, param = param, candidates = T1))
        # (`STATIC_RUNTIME_CENSUS=file` appends a line for each, to count them over many compilations: the test suite)
        haskey(ENV, "STATIC_RUNTIME_CENSUS") && open(io -> println(io, origin, "\t", callee, "\t", T0, "\t", Base.unionlen(T1), "\t", caller, "\t", census_chain(sv)), ENV["STATIC_RUNTIME_CENSUS"], "a")
    end
    return
end

# what the flow of types says of a call of the census: `(status, types it found, how many of them the call was not made over)`;
# the status is `:none` (the value is not one of an argument of the method), `:unknown` (what the callers give it is not known)
# or `:known`
function census_flow(c::Compilation, e)
    e.param === nothing && return (:none, 0, 0)
    traced = trace_param(c, e.caller, e.param)
    traced isa Symbol && return (traced, 0, 0) # (`:nocallers`: no call of the method was seen; `:abstract`: a caller gives it a type that is not concrete)
    candidates = Set{Any}(Base.uniontypes(e.candidates))
    return (:known, length(traced), count(t -> !(t in candidates), traced))
end

# The types that can be an `Any` in the program, found from what it does (the stage 2 of the notes "Principled candidates"): those
# that are stored in a slot of a container or a field of abstract elements (the slots that slots.jl knows), those that calls give to
# an argument that a method declares abstract (the types of the arguments of the calls, `record_flow_arguments!`), and the types of
# the program's own (the universe). It is compared with what calls on an `Any` are made over (the registered types and the
# universe) with `STATIC_RUNTIME_CENSUS_SETS=file`: what the program widens that the lists do not have, and what the lists have that
# it never widens.
function widened_types(c::Compilation)
    out = Set{Any}()
    function add(@nospecialize(T))
        for t in Base.uniontypes(CC.widenconst(T))
            t isa DataType && isconcretetype(t) && push!(out, t)
        end
    end
    for (key, T) in c.slots.types
        # (what an exception holds is for the code that reports it: `BoundsError.a` has the array that was indexed)
        key[2] isa Type && key[2] <: Exception && continue
        add(T)
    end
    for ((mi, n), given) in c.dispatch.flow_calls
        mi isa Core.MethodInstance || continue
        sig = Base.unwrap_unionall(mi.specTypes)
        (sig isa DataType && n <= length(sig.parameters)) || continue
        p = sig.parameters[n]
        (p isa Type && !isconcretetype(p)) || continue # (an argument that the method declares abstract)
        for T in given
            add(T)
        end
    end
    return out
end

function write_candidate_sets(c::Compilation, pass::Int)
    path = get(ENV, "STATIC_RUNTIME_CENSUS_SETS", nothing)
    path === nothing && return
    current = Set{Any}(Base.uniontypes(something(registered_union(c, Any), Union{})))
    for t in c.slots.universe
        push!(current, t)
    end
    widened = widened_types(c)
    for t in c.slots.universe
        push!(widened, t)
    end
    text(S) = join(sort!(String[string(t) for t in S]), " ; ")
    open(path, "a") do io
        println(io, "PASS\t", pass, "\tcurrent ", length(current), "\twidened ", length(widened), "\twidened-only ", length(setdiff(widened, current)), "\tcurrent-only ", length(setdiff(current, widened)))
        println(io, "WIDENED_ONLY\t", text(setdiff(widened, current)))
        println(io, "CURRENT_ONLY\t", text(setdiff(current, widened)))
    end
    return
end

# the census of a pass, written to the standard error with the trace `dispatch` (the calls in groups of the same function,
# type and origin), and, with `STATIC_RUNTIME_CENSUS_FLOW=file`, a line for each call with what the flow of types found
function trace_census(c::Compilation, pass::Int)
    write_candidate_sets(c, pass)
    census = c.dispatch.census
    flows = [census_flow(c, e) for e in census]
    if haskey(ENV, "STATIC_RUNTIME_CENSUS_FLOW")
        open(ENV["STATIC_RUNTIME_CENSUS_FLOW"], "a") do io
            for (e, f) in zip(census, flows)
                println(io, f[1], "\t", e.ncand, "\t", f[2], "\t", f[3], "\t", e.callee, "\t", e.origin)
            end
        end
    end
    trace_dispatch_on() || return
    isempty(census) && return trace("pass ", pass, ": no call was made over the registered types")
    groups = Dict{Tuple{Any,Any,Int,String},Vector{Int}}()
    for e in census
        push!(get!(Vector{Int}, groups, (e.callee, e.from, e.arg, e.origin)), e.ncand)
    end
    trace("pass ", pass, ": ", length(census), " argument", length(census) == 1 ? "" : "s", " closed to registered types, in ", length(groups), " kinds of call")
    for (k, ns) in sort!(collect(groups); by = kv -> -length(kv[2]))
        callee, from, arg, origin = k
        trace("  ", length(ns), " x ", callee, "(arg ", arg, "::", from, ") from ", origin, "; over ", minimum(ns) == maximum(ns) ? minimum(ns) : string(minimum(ns), " to ", maximum(ns)), " types")
    end
    known = [(e, f) for (e, f) in zip(census, flows) if f[1] === :known]
    nunknown = count(f -> f[1] === :nocallers || f[1] === :abstract, flows)
    trace("  flow of types: ", length(known), " of the arguments of methods found (", nunknown, " not known); over ", sum(e.ncand for (e, f) in known; init = 0),
          " types by the call, ", sum(f[2] for (e, f) in known; init = 0), " by the flow; ", sum(f[3] for (e, f) in known; init = 0), " found that the call was not made over")
    return
end

## The flow of types through the arguments of methods (`STATIC_RUNTIME_FLOW`, a shadow of what dispatch is made over)
#
# For each call of each method that is optimized: the type that it gives each argument of the method that it calls, or, if
# the argument is one of its own, which. From those, what an argument of a method can be is what its callers give it, and
# what the callers' arguments can be when they are passed on: `trace_param`. This does not change what is compiled: the
# census (above) compares it with what the call was made over, to see how much narrower it is, and whether it is ever not
# among them.

flow_shadow_on() = haskey(ENV, "STATIC_RUNTIME_FLOW")

# the methods that a call can be to, as `(method instance, the types that the call gives it)`: one for a call that inference
# found one method for, one for each case of a call that is split over a union, and each of the methods of a call that
# has several
function flow_callees(info)
    out = Tuple{Core.MethodInstance,Any}[]
    matches = Core.MethodMatch[]
    if info isa CC.MethodMatchInfo
        append!(matches, info.results.matches)
    elseif info isa CC.UnionSplitInfo
        for split in info.split
            split isa CC.MethodMatchInfo && append!(matches, split.results.matches)
        end
    end
    for m in matches
        callee = CC.specialize_method(m)
        callee isa Core.MethodInstance && push!(out, (callee, m.spec_types))
    end
    return out
end

function record_flow_arguments!(facts, ir::CC.IRCode, mi::Core.MethodInstance)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr || continue
        callees = Tuple{Core.MethodInstance,Any}[]
        first_arg = 0
        if st.head === :invoke
            target = st.args[1]
            callee = target isa Core.CodeInstance ? target.def : target
            callee isa Core.MethodInstance && push!(callees, (callee, nothing))
            first_arg = 2
        elseif st.head === :call
            callees = flow_callees(ir.stmts[pc][:info])
            first_arg = 1
        end
        for (callee, spec) in callees
            sig = Base.unwrap_unionall(callee.specTypes)
            sig isa DataType || continue
            nargs = length(st.args) - first_arg + 1
            nargs == length(sig.parameters) || continue
            for n in 2:nargs
                a = st.args[first_arg + n - 1]
                k = argument_index(ir, a)
                if k !== nothing
                    push!(facts, ((:flowpass, (callee, n), nothing), (mi, k)))
                else
                    T = CC.widenconst(CC.argextype(a, ir))
                    # (a call split over the cases of a union gives the callee of each the type of its case)
                    if spec isa DataType && n <= length(spec.parameters) && spec.parameters[n] isa Type && isconcretetype(spec.parameters[n])
                        T = spec.parameters[n]
                    end
                    push!(facts, ((:flowarg, (callee, n), nothing), T))
                end
            end
        end
    end
    return
end

# The number of the argument of the method of `sv` that the value `x` is (what is passed on unchanged: a copy, a `π`, a
# `typeassert`), or `nothing`
function argument_param(@nospecialize(sv), @nospecialize(x), depth::Int = 0)
    depth > 4 && return nothing
    x isa Core.Argument && return x.n
    code = code_statements(sv)
    code === nothing && return nothing
    if x isa Core.SlotNumber
        nargs = sv isa CC.InferenceState ? Int(sv.src.nargs) : 0
        defs = Any[st.args[2] for st in code if st isa Expr && st.head === :(=) && st.args[1] == x]
        isempty(defs) && return x.id <= nargs ? x.id : nothing
        return length(defs) == 1 ? argument_param(sv, defs[1], depth + 1) : nothing
    end
    x isa Core.SSAValue && x.id <= length(code) || return nothing
    st = code[x.id]
    st isa Core.PiNode && return argument_param(sv, st.val, depth + 1)
    (st isa Core.SSAValue || st isa Core.SlotNumber || st isa Core.Argument) && return argument_param(sv, st, depth + 1)
    if st isa Expr && (st.head === :call) && length(st.args) == 3 && callee_name(st.args[1]) == "typeassert"
        return argument_param(sv, st.args[2], depth + 1)
    end
    return nothing
end

# What the argument `k` of the method `mi` can be, from what its callers give it, as the concrete types, or `nothing` if
# it is not known: the method has no caller that was seen (an entry point, a call that is not known) or one gives it a type
# that is not concrete
function trace_param(c::Compilation, mi, k::Int, seen::Set{Any} = Set{Any}())
    key = (mi, k)
    key in seen && return Set{Any}() # (a cycle: what is passed around adds nothing)
    push!(seen, key)
    given = get(c.dispatch.flow_calls, key, nothing)
    passes = get(c.dispatch.flow_passes, key, nothing)
    (given === nothing && passes === nothing) && return :nocallers
    found = Set{Any}()
    if given !== nothing
        for T in given
            T = CC.widenconst(T)
            for t in Base.uniontypes(T)
                (t isa DataType && isconcretetype(t)) || return :abstract
                push!(found, t)
            end
        end
    end
    if passes !== nothing
        for (pmi, pk) in passes
            r = trace_param(c, pmi, pk, seen)
            r isa Symbol && return r
            union!(found, r)
        end
    end
    return found
end

function unknown_parameters_of_program(@nospecialize(T))
    T isa UnionAll || return false
    u = Base.unwrap_unionall(T)
    return u isa DataType && !isabstracttype(u) && !julia_owned_module(u.name.module)
end

# What the splitting of calls cost, for measuring (see `bench/dispatch.jl`): for each call that was split, the types
# that it had, and the number of cases that it was split in (the product of the numbers of types of its arguments). Only
# kept when `DISPATCH_STATS_ON[]` is set.
const DISPATCH_STATS_ON = Ref(false)
const DISPATCH_STATS = Dict{String,NamedTuple{(:visits, :cases, :registered),Tuple{Int,Int,Bool}}}()
function note_dispatch_split!(@nospecialize(f), original, argtypes, registered::Bool)
    DISPATCH_STATS_ON[] || return
    fname = f isa Function ? string(nameof(f)) : f isa Type ? string(f) : string(nameof(typeof(f)))
    key = string(fname, "(", join(("::" * (T isa Core.TypeofVararg ? string(T) : string(CC.widenconst(T))) for T in original[2:end]), ", "), ")")
    cases = 1
    for a in argtypes[2:end]
        a isa Core.TypeofVararg && continue
        T = CC.widenconst(a)
        cases *= T isa Union ? length(Base.uniontypes(T)) : 1
    end
    old = get(DISPATCH_STATS, key, (visits = 0, cases = cases, registered = registered))
    DISPATCH_STATS[key] = (visits = old.visits + 1, cases = cases, registered = registered)
    return
end

# What the compile that has just been done did over the registered types, as a debug message (shown with
# `JULIA_DEBUG=StaticRuntime`): a program that has a value of a type that is not one of them aborts when it
# reaches such a call (and says which one)
function report_registered_dispatch(c::Compilation)
    registered = c.dispatch.registered_calls
    isempty(registered) && return
    calls = sort!(unique!([string(f, "(", join(("::" * string(T) for T in types), ", "), ")") for (f, types) in keys(registered)]))
    empty!(registered)
    shown = join(("`$c`" for c in first(calls, 5)), ", ") * (length(calls) > 5 ? ", and $(length(calls) - 5) more" : "")
    @debug "Dispatch on `Any` or on an abstract type with unlisted subtypes was resolved over registered types: a value of another type that reaches such a call aborts the program with a MethodError. Add types with `add_dispatch_candidates!`." calls = shown candidates = join(string.(c.registered.dispatch), ", ") _id = :static_dispatch_candidates
end

# Whether the type `atype` meets one of `sigs`. (A loop, and not `any` with a closure: in the closures here a type that
# a closure takes makes it a method of its own, which Julia compiles for each type, when the program is compiled: here,
# and in the others of the package that take a type, as `holds_object_slots` does.)
function meets_any(@nospecialize(atype), sigs)
    for sig in sigs
        typeintersect(atype, sig) !== Union{} && return true
    end
    return false
end

# `show(io, T)` of a type that is a value (`DataType`) on one of the program's streams: the call of `show_type_value`,
# which prints the type's text from the table that the linker makes. (`show` for any `T` finds `T` at run time, and Julia
# can not choose a method for a `DataType`.)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Base.show), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 3 && !(argtypes[3] isa Core.Const) && CC.widenconst(argtypes[3]) === DataType
        IOT = CC.widenconst(argtypes[2])
        (IOT <: ShowStream || IOT <: Base.GenericIOBuffer) && return redirect(interp, show_type_value, Any[], 2, arginfo, si, vtypes, sv)
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

## Calls that are other calls on a target

# Functions that a target does not have are replaced, in the programs for it, by others that are written in Julia: `TARGET_REPLACEMENTS[system][f] = g` makes each call `f(args...)` in a program for
# `system` (or `:cross`: any target that is not the host's) the call `g(args...)`, which has a method for each form of call of `f`. A package that gives them (`ext/StaticRuntimeLinearAlgebraExt.jl`: the functions of BLAS and LAPACK, for a program for WebAssembly,
# which has no library to call) registers them when it is loaded (`replace_on_target!`).
const TARGET_REPLACEMENTS = Dict{Symbol,Dict{Any,Any}}()
replace_on_target!(system::Symbol, f, g) = (get!(Dict{Any,Any}, TARGET_REPLACEMENTS, system)[f] = g; nothing)
kwcall_with(g, keywords, args...) = Core.kwcall(keywords, g, args...)
function target_replacement(@nospecialize(f))
    isempty(TARGET_REPLACEMENTS) && return nothing
    table = get(TARGET_REPLACEMENTS, TARGET_SYSTEM[], nothing)
    table === nothing || (g = get(table, f, nothing)) === nothing || return g
    # (`:cross`: for every program that is made for another target than the host's)
    table = TARGET_CROSS[] ? get(TARGET_REPLACEMENTS, :cross, nothing) : nothing
    return table === nothing ? nothing : get(table, f, nothing)
end

## The target of the program, a constant

# `target_system()` and `target_arch()` (see runtime/target.jl): what the program is made for, which is the host's unless `target` says another. A constant, so that
# the code of the other systems is not looked at.
for (f, scoped) in ((:target_system, :TARGET_SYSTEM), (:target_arch, :TARGET_ARCH))
    @eval function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof($f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
        length(arginfo.argtypes) == 1 && return CC.Future(CC.CallMeta(CC.Const($scoped[]), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
    end
end

## `pkgversion` of a module, made when compiling

# `pkgversion(m)` reads the `Project.toml` of the package from its path (`ijl_module_uuid`, the file system): a program has the version that
# the package had when it was compiled, for a module that is known. (Where it is not a constant, the call is Base's, which a program can not have.)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Base.pkgversion), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 2
        m = CC.singleton_type(argtypes[2])
        if m isa Module
            v = try
                Base.invokelatest(Base.pkgversion, m)
            catch
                missing
            end
            v === missing || return CC.Future(CC.CallMeta(CC.Const(v), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

## `show` of a type that is a value, and text made when compiling

# `host_text(f, x)` (see overrides/printing.jl): the text that `f` prints for `x` in the process that compiles, made when compiling,
# in its world, when both are known; what the program has is the text.
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(host_text), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
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
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end
