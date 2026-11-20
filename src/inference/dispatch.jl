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

## The registered types: those of `show` (`add_show_candidates!`), which a value of `Any` is expected to have

"""
    add_dispatch_candidates!(types...)

Add concrete types to those that a call on a value of type `Any` (an element of a `Vector{Any}`, say), or of an abstract
type with too many subtypes to list (`Number`), dispatches over in compiled code. The defaults are numbers, `String`,
`Char`, `Symbol`, `Nothing`, `Missing` and `Vector{Any}`; the types that the program itself makes, and the types stored in
its containers of `Any`, are found without this. Use it for a value of one of Julia's types that reaches such a call some
other way (`add_dispatch_candidates!(Tuple{Int,Float64})`), or with `STATIC_RUNTIME_UNIVERSE=0`. A value of a type that is
not listed is an error when the program runs (compiling says which calls were made this way). It is the same list as
[`add_show_candidates!`](@ref)'s, and applies to every later compilation in the process: call it before compiling, not
from a package for its own types.
"""
add_dispatch_candidates!(types::Type...) = add_show_candidates!(types...)

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

# (without `Vector{Any}`, which `show` needs for lists in lists, but which has methods of arithmetic and the like, that
# call for much of what is not there, for every call with an `Any` that is a number: register it if you have lists in
# the values of the calls that you make)
const DEFAULT_DISPATCH_CANDIDATES = Type[T for T in DEFAULT_SHOW_CANDIDATES if T !== Vector{Any}]

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
# `show` is registered for (see `add_show_candidates!`): those of calls in general, and `Vector{Any}`.
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
reads_universe(c::Compilation, @nospecialize(T), show::Bool) = !show && c.settings.universe && T isa Type && !(T <: Type) && (T === Any || isabstracttype(Base.unwrap_unionall(T)) || T isa UnionAll)

function registered_union_(c::Compilation, @nospecialize(T), show::Bool, universe::Bool)
    # (a `UnionAll` that is not abstract is a type that has parameters that are not known, `Dates.DatePart`: its
    # instances are of the types of it that were registered)
    T isa Type && !(T <: Type) && (T === Any || isabstracttype(Base.unwrap_unionall(T)) || T isa UnionAll) || return nothing # (`Type{X}` is not an abstract type of objects)
    candidates = show ? c.registered.show : c.registered.dispatch
    T === Any || (candidates = vcat(candidates, c.registered.family))
    found = Type[C for C in candidates if C <: T]
    if universe && !show && c.settings.universe
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
        if u === nothing
            reads_universe(c, T, isshow) && depends!(c, sv, (:universe,)) # (see passes.jl)
            u = registered_union(c, T, isshow)
            u === nothing && continue
            reg = true
            # (only the types that some method fits are kept: the others are `MethodError`s whatever the program does,
            # and each of them counts for the limit on the number of cases that a call is split in)
            u = with_methods(c, interp, arginfo, i, u, max_methods)
            if Base.unionlen(u) > c.settings.split_limit
                # (too many with the types that the program makes: the registered ones only, as without them)
                u = registered_union(c, T, isshow; universe = false)
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
