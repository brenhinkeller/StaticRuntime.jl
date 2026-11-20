# Dynamic dispatch on abstract types, and on `Any`, resolved when compiling.
#
# A call whose argument has an abstract type (`area(x)` with `x::Shape`, from a `Vector{Shape}`) runs the method that fits
# the type that the argument has when the program is run: `ijl_apply_generic`, which looks it up in the method tables of
# the Julia runtime. There are none in a standalone binary. Julia's compiler does resolve one kind of dynamic call
# without them: for an argument of a `Union` type, it tests which type of the union it has and calls the method for that
# one ("union splitting"). So the argument is given the type of the union of the types that it can have.
#
# For an abstract type that has few concrete subtypes, that can all be listed, they are all of the types that were made when
# compiling, and so all of the types that an object of the binary can have. For `Any`, and the abstract types that have
# too many subtypes or some that are not listed (`Number`, `AbstractString`: `Complex{T}`, `SubString{T}`), it is the
# types that were *registered* (the ones of `show`, and what `add_dispatch_candidates!` adds) that are subtypes of it. An object of
# another type is not known when compiling, so a call that it reaches is a `MethodError` when the program runs (which compiling
# warns of, once for what it has done this way).
#
# That is done by inference (not in the code that results): when a call that is a dispatch on its arguments is found (more than one
# method fits, or too many to be counted, or the one that does doesn't fit all that the arguments can be), it is inferred again with the
# abstract types in its arguments replaced by the unions, and if that can be split, it is that that is used. Calls of one method that fits
# all that the arguments can be are left alone.

using StaticCompiler.GPUCompiler: GPUCompiler
using InteractiveUtils: subtypes

const CC = Base.Compiler

# The most concrete subtypes of one abstract type that we list and dispatch over.
const DISPATCH_LIMIT = Ref(16)

# The most types that a call is split in: that of the listed subtypes of an abstract type, or of the registered types. (Julia
# limits the splitting of a call by the number of its cases: `x + y` of two arguments of 23 types is not split with the limit
# at 32, and is with 64.) `0` turns the use of the registered types off.
const SPLIT_LIMIT = Ref(64)

# `GPUCompiler.inference_params` of the code that is compiled with our method table: the number of types that Julia's inference
# splits a union in, which is 4 by default, is that of the types that we dispatch over
function GPUCompiler.inference_params(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams})
    base = @invoke GPUCompiler.inference_params(job::GPUCompiler.CompilerJob)
    job.config.target.method_table === method_table || return base
    return CC.InferenceParams(base; max_union_splitting = max(base.max_union_splitting, job.config.params.split_limit))
end

## The interpreter of our compilations
#
# Inference is changed below with methods of functions of the compiler (`abstract_call_gf_by_type`, `abstract_call_known`, `optimize`) that GPUCompiler's
# interpreter (`GPUCompiler.GPUInterpreter`, which StaticCompiler's own compilations use too) is the argument of. Methods for that type would change what
# every compilation does, ours or not, and so would have to look at which it is each time. Instead, our compilations have an interpreter of a type of their
# own: the type of a `GPUInterpreter` has the type of the view of the method tables that it looks methods up in as a parameter, and GPUCompiler lets a
# back-end choose the view (`method_table_view`, which says that returning a view of another type "also gives inference a different interpreter type").
# The view here (`OverridesTableView`) holds the one that GPUCompiler makes, and does what it does; and the methods below are for the interpreters that
# have it. No other compilation is of that type, so none is changed.

"""
    OverridesTableView

The view of the method tables that our compilations are made with: that of GPUCompiler (the table of the compilation, then Base's), in a type that is ours, so that the
interpreter that has it is told from others by its type.
"""
struct OverridesTableView{T<:CC.MethodTableView} <: CC.MethodTableView
    inner::T
end
CC.isoverlayed(table::OverridesTableView) = CC.isoverlayed(table.inner)
CC.findall(@nospecialize(sig::Type), table::OverridesTableView; kwargs...) = CC.findall(sig, table.inner; kwargs...)
CC.findsup(@nospecialize(sig::Type), table::OverridesTableView) = CC.findsup(sig, table.inner)

GPUCompiler.method_table_view(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}) =
    OverridesTableView(@invoke GPUCompiler.method_table_view(job::GPUCompiler.CompilerJob))

# (the interpreter has the view in a cache, `CachedMethodTable`)
const OverridesInterpreter = GPUCompiler.GPUInterpreter{<:Union{OverridesTableView, CC.CachedMethodTable{<:OverridesTableView}}}

## the types that are registered: those of `show` (`add_show_candidates!`), which are the types that a value of `Any` is expected to have

"""
    add_dispatch_candidates!(types...)

Add concrete types to the ones that a call with an argument of the type `Any` (an element of a `Vector{Any}`, say), or of an abstract type
that has too many subtypes to list (`Number`), dispatches over in compiled code: the usual ones (numbers, `String`, `Char`, `Symbol`,
`Nothing`, `Missing`, `Vector{Any}`), and these. The types that the program makes that are not Julia's own are added without it, and
what is read from a container of `Any` is given the types that are stored in it: this is for a value of one of Julia's own types (a
`Vector{Int}`, a `Tuple{Int,Float64}`) that reaches such a call in another way, or for `STATIC_RUNTIME_UNIVERSE=0`. For example
`add_dispatch_candidates!(Tuple{Int,Float64})`. A value of another type that reaches such a call is an error when the program runs
(compiling says which calls were made this way). It is the same list as that of `show` (see [`add_show_candidates!`](@ref)). Call it
before compiling the code that has such values, and not in a package for the types of the package (it is for all the programs that the
process compiles, and they are found when a program has them).
"""
add_dispatch_candidates!(types::Type...) = add_show_candidates!(types...)

# Types that a call is made over only when the argument is of a type that they are instances of (`Dates.DatePart{'y'}` for `Dates.DatePart`), and not for `Any`: they are
# not types that a value of `Any` is likely to have, and a call with two arguments of `Any` is split over the pairs of the types, which there is a limit to (`SPLIT_LIMIT`).
function add_family_candidates!(types::Type...)
    for T in types
        isconcretetype(T) || throw(ArgumentError("$T is not a concrete type"))
    end
    register_family!(types)
    return nothing
end

# (without `Vector{Any}`, which `show` needs for lists in lists, but which has methods of arithmetic and the like, that call for much of what is
# not there, for every call with an `Any` that is a number: register it if you have lists in the values of the calls that you make)
const DEFAULT_DISPATCH_CANDIDATES = Type[T for T in DEFAULT_SHOW_CANDIDATES if T !== Vector{Any}]

## the unions that an abstract type is made

# The union of the concrete subtypes of the abstract type `T`, or `nothing` if there is no such type, or too many of them, or
# we can't tell (a subtype that is not a concrete `DataType` and is not abstract). The types that are loaded now are
# the closed world of the program that is compiled now: (it is looked up again in a newer world.)
# (what the subtypes of a type are is a fact of the world, and of the limit that they are listed to: it is kept for the compilation, by the type, the world and the limit; finding them is what takes the time)
function listed_union(c::Compilation, @nospecialize(T))
    T isa DataType && isabstracttype(T) && T !== Any || return nothing
    # (the types of functions are not listed: there is one for each function and closure, and finding them all, which `subtypes(Function)` does, takes more than a minute the first time
    # in a process that has this package loaded. The functions that a call can have are the ones of closures.jl.)
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

# The union of the registered types that are subtypes of `T` (`Any`, or an abstract type that can't be listed), or `nothing`. For a call of `show`, which is also made
# for a `Vector{Any}` in a `Vector{Any}`, they are the types that `show` is registered for (see `add_show_candidates!`): those of calls in general, and `Vector{Any}`.
function registered_union(c::Compilation, @nospecialize(T), show::Bool = false; universe::Bool = true)
    # (a `Union` is not looked up: `hash` of a union is the same for all unions, so a table with them for keys compares each with the ones that it has, which for the unions of many types is a subtype check of each pair, and they are
    # not the types that there is a union of (the answer is quick))
    T isa Union && return nothing
    key = (T, show, universe) # (the union of a type is the same for a whole pass: what it is made of is what the compilation was at its start, and the universe, which changes between passes)
    cached = get(c.dispatch.unions, key, missing)
    cached === missing || return cached
    return c.dispatch.unions[key] = registered_union_(c, T, show, universe)
end
function registered_union_(c::Compilation, @nospecialize(T), show::Bool, universe::Bool)
    # (a `UnionAll` that is not abstract is a type that has parameters that are not known, `Dates.DatePart`: its instances are of the types of it that were registered)
    T isa Type && !(T <: Type) && (T === Any || isabstracttype(Base.unwrap_unionall(T)) || T isa UnionAll) || return nothing # (`Type{X}` is not an abstract type of objects)
    candidates = show ? c.registered.show : c.registered.dispatch
    T === Any || (candidates = vcat(candidates, c.registered.family))
    found = Type[C for C in candidates if C <: T]
    if universe && !show && c.settings.universe
        # (the types that the program makes, that are not Julia's own: see slots.jl. How many there are is the limit that the call is split in, once the methods are looked at (`close_abstract_arguments`))
        for t in universe_extras(c, T)
            t in found || push!(found, t)
        end
        return isempty(found) ? nothing : Union{found...}
    end
    1 <= length(found) <= c.settings.split_limit || return nothing
    return Union{found...}
end

# (The calls that were made over the registered types, for the warning: function, and the types of its arguments: `DispatchState.registered_calls`.)

# The arguments of a call with the abstract types made unions, and the `Tuple` of their types (that of the function comes first, and
# is not changed), or `nothing` if there is none to change; and whether one of them was made of the registered types
function close_abstract_arguments(c::Compilation, interp, arginfo::CC.ArgInfo, max_methods::Int)
    argtypes = copy(arginfo.argtypes)
    changed = false
    registered = false
    isshow = CC.widenconst(argtypes[1]) === typeof(show)
    for i in 2:length(argtypes)
        argtypes[i] isa Core.TypeofVararg && continue # (a call with the arguments that are the rest of a splat: not known)
        T = CC.widenconst(argtypes[i]) # (a constant is of a concrete type; the rest of what is known of an argument is lost)
        # (a type that is not known (`Type`, `DataType`) in a program that has slots of types: one of the types that they hold, where what was read from one went through what does not keep its type, a tuple that a
        # function returns (`iterate`). The call is made over them, as over the registered types: a type of another kind is a `MethodError`)
        if c.slots.type_slots && (T === DataType || T === UnionAll || type_value_slot(T))
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
            u = registered_union(c, T, isshow)
            u === nothing && continue
            reg = true
            # (only the types that some method fits are kept: the others are `MethodError`s whatever the program does, and each of them counts for the limit on the number of cases that a call is split in)
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

# the union of `Type{X}` for the types `X` that the slots of types hold, that are of the type `T` (`DataType`, `Type{<:AbstractFunction}`), or `nothing` if there are none, or too many
function type_values_union(c::Compilation, @nospecialize(T))
    found = Any[Core.TypeEgal{X} for X in c.slots.type_values if X isa T]
    (isempty(found) || length(found) > c.settings.split_limit) && return nothing
    return Union{found...}
end

# The members of the union `u` of the types that argument `i` of the call can be that a method fits, with the other arguments as they are (the most that they can be: if no method fits the
# member then, it does not for the types that the others are closed to). A union with none is left as it is (the call is left to Julia); `u` itself if every member has one, and a type
# if one has. The methods of the function are looked up once (a function that has more than `METHOD_FILTER_LIMIT` is not filtered), and a member fits a method if the types intersect:
# what Julia does to find the methods, without looking up each member (which took much longer than what is saved).
const METHOD_FILTER_LIMIT = 64

function method_signatures(c::Compilation, interp, @nospecialize(ft), n::Int)
    world = CC.get_inference_world(interp)
    return get!(c.dispatch.signatures, (world, ft, n)) do
        found = CC.findall(Tuple{ft, Vararg{Any,n}}, CC.method_table(interp); limit = METHOD_FILTER_LIMIT)
        found === nothing || length(found.matches) > METHOD_FILTER_LIMIT ? nothing : Any[m.method.sig for m in found.matches]
    end
end

# (a call that has a splat of a length that is not known: the signatures of the methods are looked up for a number of arguments, which is not the number that it has: the methods that have another number are not the ones that
# it can not be, and the types that only they fit would be left out)
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

# whether the call is a dispatch on the types of the arguments: more than one method fits, or too many to be counted, or the one
# that does doesn't fit all that the arguments can be. (Julia resolves a call of few methods by testing the types that they have
# in their signatures, and calls that method with the argument as an object of *that* type: for an `Any` that is an abstract type
# that is not listed, and what is done with it in that method is a dispatch again. So it is the types of the objects that are
# tested here, and a type that is not known is an error.)
function dispatch_needed(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    # (an argument of a type that has parameters that are not known (`Dates.DatePart`, a parametric struct that inference has merged the instances of) is an
    # object of one of the registered types of it, whatever the one method is that fits all of them)
    for i in 2:length(arginfo.argtypes)
        arginfo.argtypes[i] isa Core.TypeofVararg && continue
        T = CC.widenconst(arginfo.argtypes[i])
        T isa UnionAll && !(T <: Type) && return true
    end
    matches = method_matches(interp, arginfo, atype, max_methods)
    matches isa CC.FailedMethodMatch && return true
    return length(matches.applicable) > 1 || !CC.fully_covering(matches)
end

# the methods that fit a call (what Julia's inference finds them with), or `FailedMethodMatch` if there are too many to count
method_matches(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int) = arginfo.fargs === nothing ?
    CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods) :
    CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods, fargs = arginfo.fargs)

# whether some method fits a call with these argument types: by the signatures of the methods of the function (looked up once: see `method_signatures`) when it has few, and else as inference finds them
function some_method_fits(c::Compilation, interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    sigs = c.settings.filter_by_methods && !has_unknown_length(arginfo) ? method_signatures(c, interp, CC.widenconst(arginfo.argtypes[1]), length(arginfo.argtypes) - 1) : nothing
    sigs === nothing || return meets_any(atype, sigs)
    matches = method_matches(interp, arginfo, atype, max_methods)
    return matches isa CC.FailedMethodMatch || !isempty(matches.applicable) # (too many to count: some fit)
end

# What Julia is told of the methods that fit, as not covering what the arguments can be, so that the call it makes is a test of each
# type (and not of all but the last, which would be what is left): what is left is a `MethodError`. For a call over the registered
# types, which an argument of the type that it has (`Any`) can be more than, so that the types that are not registered are not
# calls of the last method. (`fully_covers` of the matches of one of the types is what the union splitting of Julia looks at.)
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
                                     @nospecialize(atype), vtypes::Union{Nothing,Vector{CC.VarState}},
                                     sv::Union{CC.IRInterpretationState{I},CC.InferenceState{I}} where I<:CC.AbstractInterpreter,
                                     max_methods::Int)
    c = compilation()
    # (a call that is made for an object that is a constant: code of its own for the object, see "Any function, for each object" in objects.jl)
    if sv isa CC.InferenceState
        plan = object_call_plan(c, interp, f, arginfo.argtypes)
        plan === nothing || return redirect(interp, plan[1], plan[2], 0, arginfo, si, vtypes, sv; positions = plan[3])
    end
    registered = false
    slot_argtypes = arginfo.argtypes # (what the arguments were before they were closed: see below)
    closed = close_abstract_arguments(c, interp, arginfo, max_methods)
    # (a call that none of the types that the arguments are closed to has a method for is left as it is: it is not known what the
    # arguments are, and the result of the call is not that it is an error, which would make what calls it one too)
    closed === nothing || some_method_fits(c, interp, closed[1], closed[2], max_methods) || (closed = nothing)
    if closed !== nothing && dispatch_needed(interp, arginfo, atype, max_methods)
        original = arginfo.argtypes
        arginfo, atype, registered = closed
        note_dispatch_split!(f, original, arginfo.argtypes, registered)
        max_methods = max(max_methods, c.settings.split_limit) # (one method for each type, at most)
        if registered
            fname = f isa Function ? nameof(f) : f isa Type ? f : nameof(typeof(f))
            # (the function and the types: made into text only for the message, as this is each call that is made over them)
            key = (fname, Any[T isa Core.TypeofVararg ? T : CC.widenconst(T) for T in original[2:end]])
            calls = c.dispatch.registered_calls
            calls[key] = get(calls, key, 0) + 1
            note_dispatch_used!(c, sv)
        end
    end
    # (an argument of an abstract type: what the slots of the program hold may make it a narrower type, see slots.jl. The types are those before it was closed to the subtypes that are listed: `LinkedList{Int}` closed to the one that has a method is
    # a `Cons{Int}`, and a call that is made with it reads its fields from what may be a `Nil`, which the types of the slots are what keeps from being so)
    if !registered && !c.dispatch.registered_used && c.slots.mode !== :off
        for T in slot_argtypes[2:end]
            T isa Core.TypeofVararg && continue
            T = CC.widenconst(T)
            # (a struct of the program with parameters that are not known, `Input` of `Input{T}`, is what is read from a slot that is declared so: what the slots hold is its instances. Not Julia's own, a `Vector` or a `Dict`
            # of some type: most programs have those, and would be analyzed for them)
            if (((T isa DataType && isabstracttype(T)) || unknown_parameters_of_program(T)) && !(T <: Function) && !(T <: Type)) || type_value_slot(T)
                # (a type as a value that is not known, `Type`: it is what is read from a slot of types, see slots.jl)
                note_dispatch_used!(c, sv)
                break
            end
        end
    end
    # (a call on a type that is one of a few types, which are the cases that it is split in: Julia does not follow a call that has more methods than `max_methods`, which there can be for a function of types)
    # (only where the program has slots of types, whose reads are such unions: a union of a few types is in much of the code of Base, `convert(::Union{Type{Bool},Type{Int}}, x)`, which more methods would be looked up for)
    if c.slots.type_slots && any(a -> !(a isa Core.TypeofVararg) && (T = CC.widenconst(a); T isa Union && all(exact_type_value, Base.uniontypes(T))), arginfo.argtypes[2:end])
        max_methods = max(max_methods, c.settings.split_limit)
    end
    call = @invoke CC.abstract_call_gf_by_type(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo, atype::Any,
                    vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
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

## `@nospecializeinfer`
#
# A method that is `@nospecializeinfer` (with `@nospecialize` arguments) is inferred for the types that it is declared with, not those of the call, to keep the latency of Julia down: `Makie`'s `node_pairs(@nospecialize(nt::NamedTuple))`
# is inferred for a `NamedTuple` that has no fields known, so what it does with them (`nfields`, `getfield(nt, i)`, `fieldname(typeof(nt), i)`) is not known, which is a dynamic call for each. A program that is compiled has
# the types of the call, and needs what they give, since there is no runtime to look up what is not known: so the calls are inferred for the types that they have. The flag of the method is cleared for as long as a compilation runs
# (`restore_nospecializeinfer!` puts it back) and its inference is that of any method. `STATIC_RUNTIME_NOSPECIALIZEINFER=0` leaves them as they are.
# (the methods that were cleared are the compilation's, and are put back when it ends: `Compilation.nospecializeinfer`)
function CC.abstract_call_method(interp::OverridesInterpreter, method::Method, @nospecialize(sig), sparams::Core.SimpleVector, hardlimit::Bool, si::CC.StmtInfo, sv::CC.AbsIntState)
    c = compilation()
    if c.settings.precise_nospecializeinfer && method.nospecializeinfer
        method.nospecializeinfer = false
        push!(c.nospecializeinfer, method)
    end
    return @invoke CC.abstract_call_method(interp::CC.AbstractInterpreter, method::Method, sig::Any, sparams::Core.SimpleVector, hardlimit::Bool, si::CC.StmtInfo, sv::CC.AbsIntState)
end

function restore_nospecializeinfer!(c::Compilation)
    for m in c.nospecializeinfer
        m.nospecializeinfer = true
    end
    empty!(c.nospecializeinfer)
    return
end

# What the splitting of calls cost, for measuring (see `bench/dispatch.jl`): for each call that was split, the types that it had, and the number of cases that it was split in (the product of the
# numbers of types of its arguments). Only kept when `DISPATCH_STATS_ON[]` is set.
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

## The standard streams of Julia
#
# `stdout`, `stderr` and `stdin` of Base are globals of the abstract type `IO`, which a program has no use of (they are libuv streams), and which are the default of what packages write to (`print(stdout, ...)`, `show(stdout, x)`, `io = stdout`
# in the options of a package that prints a trace): what is done with them is a call over all the types of `IO`. A program has the streams of libc, `STDOUT`, `STDERR` and `STDIN` (see io.jl): they are what a read of the globals of Base is,
# for inference (the type), and for the code that is made (the value).
const STANDARD_STREAMS = (; stdin = STDIN, stdout = STDOUT, stderr = STDERR)

# the stream that a global is, or `nothing`
function standard_stream(@nospecialize(g))
    g isa GlobalRef && g.name in keys(STANDARD_STREAMS) || return nothing
    return Base.binding_module(g.mod, g.name) in (Base, Core) ? getfield(STANDARD_STREAMS, g.name) : nothing
end

function CC.abstract_eval_globalref(interp::OverridesInterpreter, g::GlobalRef, saw_latestworld::Bool, sv::CC.AbsIntState)
    stream = standard_stream(g)
    stream === nothing || return CC.RTEffects(CC.Const(stream), Union{}, CC.EFFECTS_TOTAL)
    return @invoke CC.abstract_eval_globalref(interp::CC.AbstractInterpreter, g::GlobalRef, saw_latestworld::Bool, sv::CC.AbsIntState)
end

# (before it is optimized, the reads of them are the streams: the type that inference gave them is not the type of what the code loads)
function replace_standard_streams!(code::Vector{Any})
    for pc in eachindex(code)
        st = code[pc]
        stream = standard_stream(st)
        if stream !== nothing
            code[pc] = stream
        elseif st isa Expr
            replace_standard_streams!(st.args)
        end
    end
    return
end

## `invokelatest`
#
# `invokelatest(f, args...)` calls `f` in the newest world, and so the compiler can't know what it calls: the call is an `Any`, made
# by the runtime. In a program that is compiled there are no newer methods, so it is the call `f(args...)`. Packages use it in the
# macros of logging (`@warn`), and sometimes to avoid a recursion that inference gives up on. So (for what is compiled with our method
# table) inference takes it for the call of `f`, and the statement is made that call before it is optimized (see `optimize`).

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.invokelatest), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 2
        inner = CC.ArgInfo(arginfo.fargs === nothing ? nothing : arginfo.fargs[2:end], arginfo.argtypes[2:end])
        return CC.abstract_call(interp, inner, si, vtypes, sv)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

## A type made of a type that is one of a few

# `ObjectiveFunction{F}()`, where `F` is the type of the objective that a solver of MathOptInterface has (`MOI.get(model, ObjectiveFunctionType())`: one of a few, of which inference knows the union of
# `Type{X}`s) is the builtin `Core.apply_type`, made when the program runs: an executable can't make types. The answer is one of a few types too: the call is inferred as the call of
# `split_apply_type`, which is made over the union (as a call of a function on a union is), with a constant type in each case, and the statement is made that call before it is optimized (see "Calls that are replaced").
split_apply_type(::Type{F}, ::Type{A}) where {F,A} = F{A}
split_apply_type(::Type{F}, ::Type{A}, ::Type{B}) where {F,A,B} = F{A,B}
split_apply_type(::Type{F}, ::Type{A}, ::Type{B}, ::Type{C}) where {F,A,B,C} = F{A,B,C}

# whether the type of an argument of `apply_type` is one type that is known (`Type{X}`, or a constant type), or a union of a few such
# (`Type{X}` is a `Core.TypeEq`, and in what inference has, a `Core.TypeEgal{X}`, which is a subtype of it)
exact_type_argument(@nospecialize(t)) = (t isa CC.Const && t.val isa Type) ||
    ((t isa Core.TypeEq || t isa Core.TypeEgal) && (p = try Base.type_parameter(t) catch; nothing end; p isa Type && !CC.has_free_typevars(p)))
function few_types_argument(@nospecialize(t))
    t isa Union || return false
    members = Base.uniontypes(t)
    # (up to 16: a type that is read from a `Vector{Type}` is one of all the types that the program stores in one, which the slot of all of them has)
    return length(members) <= 16 && all(exact_type_argument, members)
end

# the union of the types that `apply_type` makes from arguments that are each a type or a union of a few (`Union{Type{Vector{Int}},Type{Vector{Float64}}}`), or `nothing` if there are too many, or one can not be made
function applied_types(argtypes)
    choices = Any[]
    for t in argtypes[2:end]
        if t isa CC.Const
            push!(choices, Any[t.val])
        else
            push!(choices, Any[Base.type_parameter(m) for m in Base.uniontypes(t)])
        end
    end
    prod(length, choices) <= 64 || return nothing
    made = Any[]
    for combination in Iterators.product(choices...)
        R = try
            Core.apply_type(combination...)
        catch
            return nothing
        end
        push!(made, Core.TypeEgal{R})
    end
    return Union{made...}
end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.apply_type), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if 3 <= length(argtypes) <= 5 && exact_type_argument(argtypes[2]) && any(few_types_argument, argtypes[3:end]) &&
       all(t -> exact_type_argument(t) || few_types_argument(t), argtypes[3:end])
        # (what the call gives is one of the types that it makes, each a type that is known: what inference makes of the cases is a merge of constants, which is a union of at most three of them, and then
        # `Type{<:Vector}`, which a call on it is not made over the cases of)
        T = applied_types(argtypes)
        return redirect(interp, split_apply_type, Any[], 2, arginfo, si, vtypes, sv; then = T === nothing ? nothing : result_of_type, with = T)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# A tuple with an element that is one of a few types (`Tuple{Union{A,B},C}`, the pair of what two observables hold) is not a type that a value has: a value of it is one of the tuples that it is made of (`Tuple{A,C}` or
# `Tuple{B,C}`), and Julia makes and reads it with the runtime (`jl_f_tuple`, `jl_get_nth_field_checked`), as it does not know which. `Core.tuple` of an argument of a few types, and `getfield` of such a tuple, are inferred
# as calls of `split_tuple` and `split_getfield` (as a call of a function on a union is made over its cases: the tuple is made, or read, as one of a type that is known in each), and the statement is made that call before it
# is optimized (see "Calls that are replaced"), as `split_apply_type` is.
for n in 1:16 # (a method for each number of elements: a method of any number of them has a `Vararg` in its signature, which the code that looks at the calls of methods takes as a type)
    xs = [Symbol(:x, i) for i in 1:n]
    @eval split_tuple($(xs...)) = ($(xs...),)
end
split_getfield(t::Tuple, i::Int) = getfield(t, i)

# the tuple types that a tuple type of a few cases is made of (`Tuple{Union{A,B},C}`: `Tuple{A,C}` and `Tuple{B,C}`), each a type that values have, or `nothing`
function tuple_cases(@nospecialize(T), limit::Int)
    if T isa Union
        found = Any[]
        for u in Base.uniontypes(T)
            c = tuple_cases(u, limit)
            c === nothing && return nothing
            append!(found, c)
            length(found) > limit && return nothing
        end
        return found
    end
    (T isa DataType && T <: Tuple && !Base.isvatuple(T)) || return nothing
    isconcretetype(T) && return Any[T]
    found = Any[Tuple{}]
    for p in T.parameters
        options = element_cases(p, limit)
        options === nothing && return nothing
        # (a loop, and not a comprehension: its closure would have the types that it takes, and be a method that Julia compiles for each)
        next = Any[]
        for f in found, o in options
            push!(next, Tuple{(f::DataType).parameters..., o})
        end
        found = next
        length(found) > limit && return nothing
    end
    return found
end
function element_cases(@nospecialize(p), limit::Int)
    p isa Type || return nothing
    isconcretetype(p) && return Any[p]
    p isa Union && all(isconcretetype, Base.uniontypes(p)) && return Any[Base.uniontypes(p)...]
    return p isa DataType && p <: Tuple ? tuple_cases(p, limit) : nothing
end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.tuple), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) >= 2 && !any(a -> a isa Core.TypeofVararg, argtypes) && any(a -> (T = CC.widenconst(a); T isa Union && element_cases(T, compilation().settings.split_limit) !== nothing), argtypes[2:end])
        T = Tuple{(CC.widenconst(a) for a in argtypes[2:end])...}
        cases = tuple_cases(T, compilation().settings.split_limit)
        if !(cases === nothing || length(argtypes) > 17)
            # (what the call gives is the tuple that `Core.tuple` gives, `Tuple{Union{A,B},C}` or one made of what is known of the arguments: what inference makes of the cases is a merge of them, which is
            # `Tuple{Any,C}` for more than a few, where Julia has the union)
            rt = CC.tuple_tfunc(CC.typeinf_lattice(interp), argtypes[2:end])
            return redirect(interp, split_tuple, Any[], 2, arginfo, si, vtypes, sv; then = result_split, with = rt)
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# (the read of an element of a tuple of a few cases, by an index that is a constant: the call of `split_getfield` on the union of the cases, or `nothing`)
function split_tuple_read(interp, arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv)
    argtypes = arginfo.argtypes
    length(argtypes) == 3 || return nothing
    (argtypes[3] isa Core.Const && argtypes[3].val isa Int) || return nothing
    T = CC.widenconst(argtypes[2])
    (T isa Union || (T isa DataType && T <: Tuple)) && !isconcretetype(T) || return nothing
    cases = tuple_cases(T, compilation().settings.split_limit)
    (cases === nothing || length(cases) < 2) && return nothing
    # (what is read is what `getfield` gives, as for `split_tuple` above: the union of what the cases give, which inference merges)
    rt = CC.getfield_tfunc(CC.typeinf_lattice(interp), argtypes[2], argtypes[3])
    return redirect(interp, split_getfield, Any[], 2, arginfo, si, vtypes, sv; argtypes = Any[Union{cases...}, argtypes[3]], then = result_split, with = rt)
end

result_split(result::CC.CallMeta, @nospecialize(rt)) = result.rt === Union{} ? result : CC.CallMeta(split_result(result.rt, rt), result.exct, result.effects, result.info, result.refinements)

# (what a split call gives: the merge of its cases where that is the union of them, which a call on it is made over the cases of, `Union{Tuple{A,C},Tuple{B,C}}`; else what the builtin gives, `Tuple{Union{A,B},C}`, as
# inference merges more than a few tuples into one of `Any`)
function split_result(@nospecialize(merged), @nospecialize(builtin))
    T = CC.widenconst(merged)
    return (T isa Union && all(isconcretetype, Base.uniontypes(T))) || isconcretetype(T) ? merged : builtin
end

# Whether the type `atype` meets one of `sigs`. (A loop, and not `any` with a closure: in the closures here a type that a closure takes makes it a method of its own, which Julia compiles for each type, when the
# program is compiled: here, and in the others of the package that take a type, as `holds_object_slots` does.)
function meets_any(@nospecialize(atype), sigs)
    for sig in sigs
        typeintersect(atype, sig) !== Union{} && return true
    end
    return false
end

# The function that a statement of the code before it is optimized calls (what a callee refers to, if that is a variable that a
# statement before has loaded: `Base.invokelatest` is a `GlobalRef`, or `getproperty(Base, :invokelatest)`), or `nothing`
# whether a binding partition (which optimized code refers to a global by) is one of a constant: it holds the value
is_const_partition(x::Core.BindingPartition) = (x.kind & 0x0f) in (Base.PARTITION_KIND_CONST, Base.PARTITION_KIND_CONST_IMPORT, Base.PARTITION_KIND_IMPLICIT_CONST, Base.PARTITION_KIND_BACKDATED_CONST)

function called_function(code, x)
    x isa Core.SSAValue && (x = code[x.id])
    if x isa Expr && x.head === :call && length(x.args) == 3
        f = called_function(code, x.args[1])
        if f === getproperty || f === getglobal
            mod = called_function(code, x.args[2])
            name = x.args[3] isa QuoteNode ? x.args[3].value : x.args[3]
            return mod isa Module && name isa Symbol && isdefined(mod, name) ? getglobal(mod, name) : nothing
        end
        return nothing
    end
    x isa GlobalRef && return isdefined(x.mod, x.name) ? getglobal(x.mod, x.name) : nothing
    x isa QuoteNode && return x.value
    # (optimized code refers to a global through its binding partition: a constant binding holds the value)
    x isa Core.BindingPartition && return is_const_partition(x) ? x.restriction : nothing
    return x isa Expr ? nothing : x
end

## Calls that are replaced
#
# A call that a program can not make as it is (a builtin that is a call of the runtime, `getfield(x, name)` with a `name` that is not a constant; a method that finds what it needs when the program runs, `show` of a type that is a
# value) is replaced with a call of a function of this package that does the same with the types known. It is replaced in inference: the call of the replacement is what is inferred (`redirect`, in a hook of
# `abstract_call_known`), so that what it gives is what the code after it is inferred with, and what is inlined or invoked is its code, as for any call. A `RedirectInfo` says what the call is made; the statement is made
# that call before the code is optimized (`CC.optimize` below), with the information of the call of the replacement.
struct RedirectInfo <: CC.CallInfo
    f::Any              # the function that is called in its place
    prefix::Vector{Any} # the constants that it is given before the arguments of the call
    positions::Vector{Int} # the arguments of the call that it is given after those (`call.args[positions]`, with `call.args[1]` the function)
    info::CC.CallInfo      # what inference has of the call of `f`
end
CC.add_edges_impl(edges::Vector{Any}, info::RedirectInfo) = CC.add_edges!(edges, info.info)

# The call `f(prefix..., args[from:to]...)` in place of the call of `arginfo`, as inference has it (or of the arguments at `positions`, if they are given). `argtypes`, if they are given, are what the replacement is inferred with
# (the types of the arguments that it is given, which may be narrower than those of the call: the cases of a split); `then(result, with)`, if it is given, makes what inference has of the call of the replacement what the call
# gives (what it gives in Julia, which may be more than inference finds of the replacement: a merge of its cases).
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

# The same, decided by what Julia infers of the call: `decide(result)` gives the arguments of `redirect` (`(f, prefix, from)`), or `nothing` for the call as Julia has it. (Julia's call is inferred in a task of inference, and so
# is the replacement, after it: see `doworkloop` in Julia's compiler.)
function redirect_after(decide, interp::CC.AbstractInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv::CC.AbsIntState, max_methods::Int)
    result = CC.Future{CC.CallMeta}()
    state = Ref{Any}(nothing)
    stage = Ref(0)
    function step(interp, sv)
        if stage[] == 0
            state[] = @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                                     vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
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

# (before optimizing: the statements of `invokelatest` are the calls that inference took them for)
function CC.optimize(interp::OverridesInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
    code = opt.src.code
    replace_standard_streams!(code)
    c = compilation()
    findings = caller.overridden_by_const === nothing ? findings!(caller) : nothing # (what is found of the code is kept with its result, for the compilations that take it from the cache: see `InferenceFindings`)
    c.closures.sink = findings
    try
        note_functions_of!(c.closures, code, opt.src.ssavaluetypes, caller.linfo) # (the functions that the code has: see closures.jl)
    finally
        c.closures.sink = nothing
    end
    if caller.linfo isa Core.MethodInstance
        findings === nothing || any(st -> box_creation(code, st) !== nothing, code) && push!(findings.boxes, (copy(opt.src), caller.linfo))
        learn_boxes!(c.boxes, opt.src, caller.linfo) # (the types of the boxes of the code: see boxes.jl)
    end
    for pc in eachindex(code)
        st = code[pc]
        # (a call that is assigned to a variable is the second of the arguments of `=`)
        assigned = st isa Expr && st.head === :(=) && length(st.args) == 2 && st.args[2] isa Expr
        call = assigned ? st.args[2] : st
        call isa Expr && call.head === :call && length(call.args) >= 2 || continue
        called = called_function(code, call.args[1])
        # (`NamedTuple{names}(args)` that was given the type of its argument, see `abstract_call_known` for `NamedTuple` in closures.jl: the call is of the type that it gives, as the code that is made of it makes a value of the type that it is called)
        let t = opt.src.ssavaluetypes[pc], called = (a = call.args[1]; a isa Core.SSAValue && (ft = opt.src.ssavaluetypes[a.id]) isa CC.Const ? ft.val : called)
            if called isa UnionAll && called.body isa DataType && called.body.name === Base.typename(NamedTuple) && length(call.args) == 2 &&
               t isa DataType && t.name === Base.typename(NamedTuple) && t !== called && t <: called
                call.args[1] = t
                continue
            end
        end
        # (the keywords of a call that has a type as a value: the constant that the call is given is one of the type that has the type as the type of the field, as the method was inferred for, see `typed_keywords`. Only the
        # argument of the call: the value is what it is everywhere else, and `typeof` of it is what Julia says)
        if called === Core.kwcall && length(call.args) >= 2
            kw = call.args[2]
            t = kw isa Core.SSAValue ? opt.src.ssavaluetypes[kw.id] : kw isa NamedTuple ? CC.Const(kw) : nothing
            t isa CC.Const && has_type_values(t.val) && (call.args[2] = typed_constant(t.val))
        end
        info = opt.stmt_info[pc]
        if info isa RedirectInfo
            # (a call that is replaced, see "Calls that are replaced": the call of the replacement, with what inference has of it)
            replacement = Expr(:call, info.f, info.prefix..., call.args[info.positions]...)
            opt.stmt_info[pc] = info.info
            assigned ? (st.args[2] = replacement) : (code[pc] = replacement)
            continue
        end
        replacement = if called === host_text && opt.src.ssavaluetypes[pc] isa CC.Const
            # (the text that was made when compiling, see `host_text` in show.jl: the statement is the text, which Julia does not put in the place of a call that it is the value of, as it is not a value of bits)
            opt.src.ssavaluetypes[pc].val
        elseif called === Core.invokelatest
            Expr(:call, call.args[2:end]...)
        elseif (called === Core.memoryrefget || called === Core.getfield) && (slot_call = type_slot_call(opt.stmt_info[pc])) !== nothing
            slot_call[1] === type_slot_get ? Expr(:call, type_slot_get, call.args[2], slot_call[2]) : Expr(:call, type_slot_field, call.args[2], Val(call.args[3] isa QuoteNode ? call.args[3].value : call.args[3]), slot_call[2])
        elseif (keyed = keyed_replacement(c, called, call, opt.stmt_info[pc], opt.src.ssavaluetypes[pc])) !== nothing
            # (code for each object, and the constants that it has: see "Code for each object" in objects.jl)
            keyed
        elseif called === call_callback && length(call.args) >= 3
            # (`call_callback(T, f, args...)` is `f(args...)`, or no call at all where no function was registered for `T`: see closures.jl)
            opt.src.ssavaluetypes[pc] === Union{} ? Expr(:call, Core.throw, "a callback that was not registered") : Expr(:call, call.args[3:end]...)
        else
            continue
        end
        assigned ? (st.args[2] = replacement) : (code[pc] = replacement)
    end
    # (what the analysis of the slots finds of the code of this method is kept with its result: see `SlotFactsResult`)
    previous = c.slots.current_result
    c.slots.current_result = caller
    try
        if c.trace.on
            c.closures.optimized += 1
            push!(c.closures.optimized_unique, caller.linfo)
            started = time_ns()
            result = @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
            note_slow_optimization!(c.closures, caller.linfo, (time_ns() - started) / 1e9, length(code))
            return result
        end
        return @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
    finally
        c.slots.current_result = previous
    end
end

## Fields of `Union{T,Nothing}`
#
# `node.next.value` where `node.next::Union{Node,Nothing}`: Julia splits the calls on the union when it inlines them, but the code that it inlines keeps using the value of the union, so it reads
# `getfield(x, :value)` of `x::Union{Node,Nothing}`, which is compiled as a call of the runtime (`jl_f_getfield`: it looks at the type of `x` and then at its fields). The part of the union that is
# not `Nothing` is the only one that has the field, so the value is asserted to be that type first: if it is `nothing` the program stops, as it does in Julia (with a `FieldError`).
const FIELD_BUILTINS = (Core.getfield, Core.setfield!)

# (for `STATIC_RUNTIME_TRACE`: the calls that have no method for the types that reach them, which abort the program if they are reached: the function, the types of the arguments, and the method that has the call)
function trace_method_errors(ir::CC.IRCode, linfo)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call || continue
        f = st.args[1]
        (f === Core.throw_methoderror || (f isa GlobalRef && f.name === :throw_methoderror)) || continue
        trace("no method for ", join((CC.widenconst(CC.argextype(a, ir)) for a in st.args[2:end]), ", "), " in ", linfo)
    end
    return
end

# A type that has `Union{}` as one of its parameters (`Pairs{Symbol,Union{},...}`, `Type{Union{}}`): no value has it, so a call that has an argument of it gives no value, and the code after it is unreachable. Where inference is wrong
# about a type (it was, for `eltype` of some tuple types: see `_compute_eltype` in overrides/base.jl) the program has a trap where it should have a value, and says nothing about it.
function has_bottom_parameter(@nospecialize(T), depth::Int = 0)
    depth > 6 && return false
    T = CC.widenconst(T)
    if T isa Union
        return any(U -> has_bottom_parameter(U, depth + 1), Base.uniontypes(T))
    elseif T isa DataType || T isa Core.TypeEq # (`Type{X}` is a `TypeEq`, not a `DataType`, in Julia 1.14)
        for P in (T isa Core.TypeEq ? (Base.type_parameter(T),) : T.parameters)
            P === Union{} && return true
            P isa Type && has_bottom_parameter(P, depth + 1) && return true
        end
    end
    return false
end

# (for `STATIC_RUNTIME_TRACE`: the calls that give no value, and have an argument that has a type that no value has, or a `NamedTuple` that is not a concrete type, which is what a call is inferred for when what made its argument was
# given the wrong type. A call that always throws has no such argument: those are not shown)
function trace_noreturn(ir::CC.IRCode, linfo)
    for pc in 1:length(ir.stmts)
        ir.stmts[pc][:type] === Union{} || continue
        st = ir.stmts[pc][:stmt]
        st isa Expr && (st.head === :call || st.head === :invoke) || continue
        args = st.head === :invoke ? st.args[2:end] : st.args
        length(args) >= 1 || continue
        types = Any[CC.widenconst(CC.argextype(a, ir)) for a in args]
        f = CC.singleton_type(types[1])
        (f === Core.throw || f === Core.Intrinsics.llvmcall) && continue
        suspicious = [T for T in types[2:end] if has_bottom_parameter(T) || (T isa DataType && T.name === Base.typename(NamedTuple) && !isconcretetype(T))]
        isempty(suspicious) && continue
        trace("the call ", f === nothing ? types[1] : f, "(", join(types[2:end], ", "), ") gives no value, and an argument of it has a type that no value has or is not concrete: ", join(suspicious, ", "), " in ", linfo)
    end
    return
end

# A type that is built and not used. `x isa CallbackSet{<:AbstractVector,<:AbstractVector}` that inference found the answer of leaves the statements that make the type (`Core._typevar` for each `<:`, and `Core.apply_type` of them), which Julia does not
# remove as they are not known to be without effect (a `TypeVar` is mutable), and which are a call of the runtime. The statements of these kinds whose values are not used are removed (and so are the ones that only they used).
const TYPE_BUILDERS = (Core._typevar, Core.apply_type, Core.UnionAll)
function remove_unused_type_construction!(ir::CC.IRCode)
    n = length(ir.stmts)
    candidates = Int[]
    for pc in 1:n
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && !isempty(st.args) || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) in TYPE_BUILDERS && push!(candidates, pc)
    end
    isempty(candidates) && return ir
    uses = zeros(Int, n)
    for pc in 1:n
        for ur in CC.userefs(ir.stmts[pc][:stmt])
            v = ur[]
            v isa Core.SSAValue && v.id <= n && (uses[v.id] += 1)
        end
    end
    changed = false
    for pc in reverse(candidates)
        uses[pc] == 0 || continue
        st = ir.stmts[pc][:stmt]
        for ur in CC.userefs(st)
            v = ur[]
            v isa Core.SSAValue && v.id <= n && (uses[v.id] -= 1)
        end
        ir.stmts[pc][:stmt] = nothing
        ir.stmts[pc][:type] = Nothing
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

function CC.finishopt!(interp::OverridesInterpreter, opt::CC.OptimizationState, ir::CC.IRCode)
    c = compilation()
    ir = assert_assumed_returns!(c, ir, opt.linfo)
    # (not in `type_slot_get` and `type_slot_field`: what they read is what they check)
    (c.settings.check_types || !isempty(c.registered.fields) || !isempty(c.registered.embedded)) && !in_type_slot_read(opt) && (ir = check_slot_reads!(c, ir))
    ir = assert_field_receivers!(ir)
    ir = expand_type_value_tests!(ir)
    ir = concretize_type_tuples!(ir)
    ir = expand_tuple_reads!(ir)
    ir = expand_setproperty!(ir)
    t = c.trace
    t.methoderrors && trace_method_errors(ir, opt.linfo)
    t.methoderrors && trace_noreturn(ir, opt.linfo) # (not with `STATIC_RUNTIME_TRACE=1`: in a large program there are thousands, and writing their types took a quarter of the time)
    ir = concretize_namedtuples!(ir)
    ir = remove_unused_type_construction!(ir)
    # (`STATIC_RUNTIME_TRACE=ir:<text>`: the code of the methods whose name has the text in it, as it is now)
    isempty(t.ir) || (name = string(opt.linfo); occursin(t.ir, name) && trace("the code of ", name, ", optimized:\n", ir))
    return @invoke CC.finishopt!(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, ir::CC.IRCode)
end

# What is read from a slot that has types (see slots.jl) is checked to be of them, for finding what stores a program has that are not seen: the read is `typeassert`ed to the type that it was given. (It would have
# been `Any` otherwise, and the calls on it dispatched over the registered types.) Only for reads whose type is narrower than what the slot is declared to hold.
function check_slot_reads!(c::Compilation, ir::CC.IRCode)
    changed = false
    reads = Dict{Int,SlotKey}() # (the statements that read a slot that was given types, and are checked)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) >= 3 || continue
        f = CC.singleton_type(CC.argextype(st.args[1], ir))
        key = nothing
        if f === Core.getfield
            name = CC.argextype(st.args[3], ir)
            name isa Core.Const && (name.val isa Symbol || name.val isa Integer) || continue
            key = field_slot_key(CC.argextype(st.args[2], ir), name.val)
        elseif f === Core.memoryrefget
            key = elem_slot_key(CC.argextype(st.args[2], ir))
        else
            continue
        end
        key === nothing && continue
        # (a read of a slot that was given types, or of a field of an object that is known: see objects.jl)
        (slot_read_type(c, key) !== nothing || (f === Core.getfield && known_object(c, CC.argextype(st.args[2], ir)) !== nothing)) || continue
        (c.settings.check_types || haskey(c.registered.fields, key) || key in c.registered.embedded) || continue # (what is assumed is always checked)
        reads[pc] = key
        T = CC.widenconst(ir.stmts[pc][:type])
        (T !== Union{} && closed_type(T)) || continue
        wide = key[1] === :elem ? key[2] : fieldtype(key[2], key[3])
        T === wide && continue
        read = CC.insert_node!(ir, pc, CC.NewInstruction(st, wide), false)
        ir.stmts[pc][:stmt] = Expr(:call, Core.typeassert, read, T)
        changed = true
    end
    # (a read that inference narrowed with a `PiNode` of its value, which is not a check: it is the type that was claimed, and one that the value may not have)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Core.PiNode && st.val isa Core.SSAValue && haskey(reads, st.val.id) && st.typ isa Type || continue
        ir.stmts[pc][:stmt] = Expr(:call, Core.typeassert, st.val, st.typ)
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

## Types as values: what is read from a slot of types

# What is read from a slot of types (`Vector{Type}`, a field of the type `Type`) is of the types that were stored in it (see slots.jl): `Union{Type{Int},Type{Float64}}`. The read is checked, as every read of a slot is: a store that
# the compiler did not see (a method that is given a type and stores it, and is not inlined) would be a type that the code that is made over the union does not have a case for. It is a call of `type_slot_get` (or
# `type_slot_field`, for a field), which inference is made to take the read for and the optimizer to call (the type is given as a `Val`: a generated function is made for the types of its arguments, which are not those of `Type{Union{...}}`), and which gives the type that the value is, as a constant: `v === Int ? Int : v === Float64 ? Float64 : error`. (A union of
# types of the program is not tested with `isa`: that is a call of the runtime for `Type{X}`.)
mentions_type_value(@nospecialize(T)) = any(m -> exact_type_value(m) || (m isa DataType && m <: Tuple && any(p -> p isa Type && mentions_type_value(p), m.parameters)), Base.uniontypes(T))

# The members of the type `U` as a tuple of `Val`s (a generator over the type alone: the value that is checked is of a type that is not concrete (`Type`), which a generator can not be made for), and what is asked of each: whether
# the value is it, and what it then is: a type is itself (a constant), and the value as it is for a tuple (the types of its elements are those that the code that reads them was inferred with) and for a type that is concrete.
@generated members(::Val{U}) where {U} = Expr(:tuple, (:(Val{$(QuoteNode(m))}()) for m in Base.uniontypes(U))...)

@inline matches_any(v, ::Tuple{}) = false
@inline matches_any(v, ms::Tuple) = matches_member(v, first(ms)) | matches_any(v, Base.tail(ms))
@inline value_any(v, ::Tuple{}) = Core.throw("a type that was stored in a slot of types was not found when compiling")
@inline value_any(v, ms::Tuple) = matches_member(v, first(ms)) ? member_value(v, first(ms)) : value_any(v, Base.tail(ms))

# the type `X` of `Type{X}` (a generator, which is run when compiling)
@generated type_value_constant(::Val{M}) where {M} = QuoteNode(type_value_parameter(M))

@inline matches_member(v, ::Val{M}) where {M} = (M isa Core.TypeEq || M isa Core.TypeEgal) ? v === type_value_constant(Val{M}()) : (M <: Tuple && !isconcretetype(M)) ? matches_tuple(v, Val{M}()) : Core.isa(v, M)
@inline member_value(v, ::Val{M}) where {M} = (M isa Core.TypeEq || M isa Core.TypeEgal) ? type_value_constant(Val{M}()) : (M <: Tuple && !isconcretetype(M)) ? Core.typeassert(v, concrete_tuple_type(Val{M}())) : Core.typeassert(v, M)

# the type that a tuple of the type `M` (which has types as elements) is: `Tuple{DataType,Float64}` for `Tuple{Union{Type{Int},Type{Float64}},Float64}`; and `M` if it is not known (see `concretize_type_tuples!`)
@generated function concrete_tuple_type(::Val{M}) where {M}
    elements = Any[]
    for p in M.parameters
        members = Base.uniontypes(p)
        kinds = unique(exact_type_value(m) ? typeof(type_value_parameter(m)) : m for m in members)
        length(kinds) == 1 && isconcretetype(kinds[1]) || return QuoteNode(M)
        push!(elements, kinds[1])
    end
    return QuoteNode(Tuple{elements...})
end

# whether each element of a tuple (of the type that it is, a concrete one: `Tuple{DataType,Float64}`, which a generator can be made for, and which has its elements read with the index known) is one of the types that the element can be
@generated function matches_elements(w, ::Val{M}) where {M}
    tests = Any[:(matches_any(getfield(w, $i), members(Val{$(QuoteNode(fieldtype(M, i)))}()))) for i in 1:fieldcount(M)]
    return foldl((a, b) -> :($a & $b), tests)
end
@inline function matches_tuple(v, ::Val{M}) where {M}
    CT = concrete_tuple_type(Val{M}())
    return Core.isa(v, CT) && matches_elements(Core.typeassert(v, CT), Val{M}())
end

@inline checked_type_value(v, ::Val{U}) where {U} = value_any(v, members(Val{U}()))
@inline type_slot_get(ref, ::Val{U}) where {U} = checked_type_value(Core.memoryrefget(ref, :not_atomic, false), Val{U}())
@inline type_slot_field(x, ::Val{name}, ::Val{U}) where {name,U} = checked_type_value(Core.getfield(x, name), Val{U}())

# whether the code that is inferred is one of these (what they read is the slot itself, not what is given to it)
function in_type_slot_read(sv)
    mi = sv isa CC.OptimizationState ? sv.linfo : CC.frame_instance(sv)
    return mi isa Core.MethodInstance && mi.def isa Method && parentmodule(mi.def) === (@__MODULE__) && (mi.def.name === :type_slot_get || mi.def.name === :type_slot_field)
end

# the call that the statement was taken for (by `type_slot_get` or `type_slot_field`), as the function and the type that is checked, or `nothing`
function type_slot_call(@nospecialize(info))
    info isa CC.MethodMatchInfo || return nothing
    matches = info.results.matches
    length(matches) == 1 || return nothing
    m = only(matches).method
    (parentmodule(m) === (@__MODULE__) && (m.name === :type_slot_get || m.name === :type_slot_field)) || return nothing
    V = only(matches).spec_types.parameters[end]
    (V isa DataType && V <: Val && length(V.parameters) == 1 && V.parameters[1] isa Type) || return nothing
    return (m.name === :type_slot_get ? type_slot_get : type_slot_field), Val{V.parameters[1]}()
end

## Types as values: tests of what a type is

# `isa(x, Type{Int})` (what a call over the types that a value can be is made of: a union of `Type{X}`, and Julia tests the value against each member) is a call of the runtime, which looks at what `Type{Int}` is: for a type that is
# one type it is `x === Int`, and for a union of them the tests that are or-ed.
function type_value_test(ir::CC.IRCode, @nospecialize(operand))
    t = CC.argextype(operand, ir)
    t isa CC.Const && t.val isa Type || return nothing
    U = t.val
    all(exact_type_value, Base.uniontypes(U)) || return nothing
    return U
end

# the bounds `(lower, upper)` of what `isa` tests against, if it is `Type{T} where lb<:T<:ub` (a method that takes `Type{<:S}`), or `nothing`
function type_bounds_test(ir::CC.IRCode, @nospecialize(operand))
    t = CC.argextype(operand, ir)
    t isa CC.Const && t.val isa UnionAll || return nothing
    u = t.val
    u.body isa Type && u.body === Type{u.var} || return nothing
    (u.var.lb isa Type && u.var.ub isa Type) || return nothing
    return u.var.lb, u.var.ub
end

function expand_type_value_tests!(ir::CC.IRCode)
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) == 3 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) === Core.isa || continue
        x = st.args[2]
        bounds = type_bounds_test(ir, st.args[3])
        if bounds !== nothing && CC.widenconst(CC.argextype(x, ir)) <: Type
            # (`isa(x, Type{<:S})`, for the type `x` that is a type: `x <: S`)
            lb, ub = bounds
            result = Expr(:call, Core.:(<:), x, ub)
            if lb !== Union{}
                previous = CC.insert_node!(ir, pc, CC.NewInstruction(result, Bool), false)
                this = CC.insert_node!(ir, pc, CC.NewInstruction(Expr(:call, Core.:(<:), lb, x), Bool), false)
                result = Expr(:call, Core.Intrinsics.and_int, previous, this)
            end
            ir.stmts[pc][:stmt] = result
            changed = true
            continue
        end
        U = type_value_test(ir, st.args[3])
        U === nothing && continue
        result = nothing
        for m in Base.uniontypes(U)
            test = Expr(:call, Core.:(===), x, type_value_parameter(m))
            if result === nothing
                result = test
            else
                previous = CC.insert_node!(ir, pc, CC.NewInstruction(result, Bool), false)
                this = CC.insert_node!(ir, pc, CC.NewInstruction(test, Bool), false)
                result = Expr(:call, Core.Intrinsics.or_int, previous, this)
            end
        end
        ir.stmts[pc][:stmt] = result
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

# A tuple that has types as elements (`(Int, Float64)` of a union of them that is read from a slot) has the type of its elements, which are all `DataType`: `Tuple{DataType,DataType}`, which is a type that has a size, and is made
# in the code. (The type that is known is `Tuple{Type,Type}`, which is not the type of any tuple: a tuple of it is made with a call of the runtime, which finds the type of each element.) Where each element is a type or
# one of a few, whose types are all the same, the tuple is made as `Tuple{DataType,...}`.
# The types of the types that an operand can be (`DataType` for `Int`, `UnionAll` for `Vector`), if it is a type that is known, a union of them, or a `φ` of such (where inference merged the constants that come
# into it to `Any`, as it does for more than a few); or `nothing`
function type_kinds(ir::CC.IRCode, @nospecialize(a), depth::Int = 0)
    depth > 8 && return nothing
    t = CC.argextype(a, ir)
    t isa CC.Const && return t.val isa Type ? Any[typeof(t.val)] : nothing
    members = Base.uniontypes(CC.widenconst(t))
    !isempty(members) && all(exact_type_value, members) && return unique!(Any[typeof(type_value_parameter(m)) for m in members])
    a isa Core.SSAValue && a.id <= length(ir.stmts) || return nothing
    st = ir.stmts[a.id][:stmt]
    st isa Core.PiNode && return type_kinds(ir, st.val, depth + 1)
    st isa Core.PhiNode || return nothing
    kinds = Any[]
    for i in eachindex(st.values)
        isassigned(st.values, i) || continue
        k = type_kinds(ir, st.values[i], depth + 1)
        k === nothing && return nothing
        append!(kinds, k)
    end
    return isempty(kinds) ? nothing : unique!(kinds)
end

function concretize_type_tuples!(ir::CC.IRCode)
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) >= 2 || continue
        f = CC.singleton_type(CC.argextype(st.args[1], ir))
        if f === Core.getfield && length(st.args) >= 3
            # (an element of a tuple that has types as elements, of the type that the program has for it: `Tuple{Type,Type}`, which no tuple is. The elements of all tuples of types are references, whichever of
            # `DataType`, `UnionAll` and `Union` each is, so the tuple is read as `Tuple{DataType,DataType}`, as a read of a tuple that has a type that is concrete is: a load, and not a call of the runtime)
            X = CC.widenconst(CC.argextype(st.args[2], ir))
            if X isa DataType && X <: Tuple && !isconcretetype(X) && !isempty(X.parameters) && all(p -> p isa Type && (isconcretetype(p) || p === Type), X.parameters) && any(p -> p === Type, X.parameters)
                C = Tuple{(p === Type ? DataType : p for p in X.parameters)...}
                isconcretetype(C) || continue
                st.args[2] = CC.insert_node!(ir, pc, CC.NewInstruction(Core.PiNode(st.args[2], C), C), false)
                changed = true
            end
            continue
        end
        f === Core.tuple || continue
        T = CC.widenconst(ir.stmts[pc][:type])
        (T isa DataType && T <: Tuple && !isconcretetype(T) && length(T.parameters) == length(st.args) - 1) || continue
        elements = Any[]
        any_type = false
        for a in st.args[2:end]
            kinds = type_kinds(ir, a)
            if kinds !== nothing
                length(kinds) == 1 || (elements = nothing; break)
                push!(elements, kinds[1]); any_type = true
            else
                W = CC.widenconst(CC.argextype(a, ir))
                isconcretetype(W) || (elements = nothing; break)
                push!(elements, W)
            end
        end
        (elements === nothing || !any_type) && continue
        C = Tuple{elements...}
        isconcretetype(C) || continue
        ir.stmts[pc][:stmt] = Expr(:new, C, st.args[2:end]...)
        ir.stmts[pc][:type] = C
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

function assert_field_receivers!(ir::CC.IRCode)
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) >= 3 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) in FIELD_BUILTINS || continue
        receiver = CC.widenconst(CC.argextype(st.args[2], ir))
        receiver isa Union || continue
        parts = filter(T -> !(T === Nothing || T === Missing), Base.uniontypes(receiver))
        length(parts) == 1 && isconcretetype(only(parts)) && length(Base.uniontypes(receiver)) > 1 || continue
        T = only(parts)
        checked = CC.insert_node!(ir, pc, CC.NewInstruction(Expr(:call, Core.typeassert, st.args[2], T), T), false)
        st.args[2] = checked
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

# `getfield(x, name)` of a struct, with a `name` that is not a constant, is `jl_f_getfield` too, and the type of what it gives depends on `name`: it is the call of `struct_field`, which is a comparison with each name (or
# `index_field`, for an index), in its place (see "Calls that are replaced"); `nothing` where it is not. (`abstract_call_known` for `getfield` in boxes.jl.)
function dynamic_field_plan(argtypes::Vector{Any})
    3 <= length(argtypes) <= 4 || return nothing
    name = argtypes[3]
    name isa Core.Const && return nothing
    kind = CC.widenconst(name)
    (kind === Symbol || kind === Int) || return nothing
    T = CC.widenconst(argtypes[2])
    (T isa DataType && isconcretetype(T) && !(T <: Type) && T !== DataType && T !== Module &&
     Base.datatype_fieldcount(T) isa Int && 0 < Base.datatype_fieldcount(T) <= 64) || return nothing
    # (not a tuple: see `expand_tuple_reads!`)
    T <: Tuple && return nothing
    return kind === Symbol ? struct_field : index_field
end

# `getfield(t, i)` of a tuple by an index that is not a constant (`t[i]` in a loop over its elements): what Julia infers it to give is the union of the types of the elements, which is narrower than what the code of
# `index_field` gives where they are constants (a tuple of types: what inference makes of more than three constants is the `DataType` that they are all of), and the analysis of the slots reads the type of what is stored
# from the call (`Type[A, B, C, D]`). So it is left as Julia's call through optimization, and made a call of `index_field` after, with that type. (A field of another struct is replaced in inference: see
# `dynamic_field_plan`.)
function expand_tuple_reads!(ir::CC.IRCode)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && 3 <= length(st.args) <= 4 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) === Core.getfield || continue
        i = CC.argextype(st.args[3], ir)
        (!(i isa Core.Const) && CC.widenconst(i) === Int) || continue
        T = CC.widenconst(CC.argextype(st.args[2], ir))
        (T isa DataType && T <: Tuple && isconcretetype(T) && Base.datatype_fieldcount(T) isa Int && 0 < Base.datatype_fieldcount(T) <= 64) || continue
        mi = CC.specialize_method(only(methods(index_field)), Tuple{typeof(index_field),T,Int}, Core.svec())
        ir.stmts[pc][:stmt] = Expr(:invoke, mi, index_field, st.args[2], st.args[3])
        # (the elements of a tuple of types that is a constant: each is a type that is known, see `types_of_constant_tuple`, where the callee gives the `DataType` that they are all of)
        types = types_of_constant_tuple(Any[nothing, CC.argextype(st.args[2], ir), i])
        types === nothing || (ir.stmts[pc][:type] = types)
    end
    return ir
end

# `isdefined(x, name)` with a `name` that is not a constant: the call of `struct_isdefined`, the same comparisons (`get(f, nt, name)` and `haskey(nt, name)` of a `NamedTuple` are that)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.isdefined), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 3 && !(argtypes[3] isa Core.Const) && CC.widenconst(argtypes[3]) === Symbol
        T = CC.widenconst(argtypes[2])
        if T isa DataType && isconcretetype(T) && isstructtype(T) && !(T <: Type) && !(T <: Tuple) && T !== Module && Base.datatype_fieldcount(T) isa Int && Base.datatype_fieldcount(T) <= 64
            return redirect(interp, struct_isdefined, Any[], 2, arginfo, si, vtypes, sv)
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# A vector literal with a splat of something that is not a tuple (see `splat_vector`): the call of `splat_vector` with the parts of the splat, where Julia's call is one of the runtime. It is Julia's where Julia knows the
# number of the elements of each part (tuples, a static vector, whose elements it iterates: it makes the call with them), which it says in what it has of the call (an `ApplyCallInfo` with the iteration of each part
# that is not a tuple).
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core._apply_iterate), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    plan = splat_plan(arginfo.argtypes)
    plan === nothing && return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                                               vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
    parts = Any[CC.widenconst(t) for t in arginfo.argtypes[4:end]]
    return redirect_after(interp, f, arginfo, si, vtypes, sv, max_methods) do result
        julia_iterates_all(result.info, parts) ? nothing : plan
    end
end

fixed_tuple(@nospecialize(P)) = P isa DataType && P <: Tuple && !any(Base.isvarargtype, P.parameters)

function julia_iterates_all(@nospecialize(info), parts::Vector{Any})
    info isa CC.ApplyCallInfo && length(info.arginfo) == length(parts) || return false
    for k in eachindex(parts)
        fixed_tuple(parts[k]) || info.arginfo[k] !== nothing || return false
    end
    return true
end

# (the arguments of `redirect` for the splat: `splat_vector(Val(T), Val(skip), parts...)`, or `nothing` for a call that is not a vector literal, has only tuples, or whose type depends on more than the types)
function splat_plan(argtypes::Vector{Any})
    length(argtypes) >= 4 || return nothing
    CC.singleton_type(argtypes[2]) === Base.iterate || return nothing
    g = CC.singleton_type(argtypes[3])
    (g === Base.vect || g === Base.getindex) || return nothing
    parts = Any[CC.widenconst(t) for t in argtypes[4:end]]
    length(parts) <= SPLAT_MAX_PARTS || return nothing
    all(fixed_tuple, parts) && return nothing
    all(isconcretetype, parts) || return nothing
    if g === Base.getindex
        # (`T[...]`: the type is the first element of the first part, a constant)
        first_part = argtypes[4]
        fixed_tuple(parts[1]) && fieldcount(parts[1]) >= 1 || return nothing
        T = first_part isa Core.Const ? first_part.val[1] :
            first_part isa CC.PartialStruct && first_part.fields[1] isa Core.Const ? first_part.fields[1].val : nothing
        T isa Type || return nothing
        return (splat_vector, Any[Val(T), Val(true)], 4)
    end
    _, spread, types = splat_items(parts, false)
    splat_types(types, spread) === nothing && return nothing
    return (splat_vector, Any[Val(:promote), Val(false)], 4)
end

# `show(io, T)` of a type that is a value (`DataType`), not a constant, on one of the streams of the program: the call of `show_type_value`, which prints the text of the type from the table that the linker makes. (The
# method of `show` for any `T` finds `T` when the program runs, and Julia does not choose a method for a `DataType`, which may be any `Type{T}`.)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Base.show), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 3 && !(argtypes[3] isa Core.Const) && CC.widenconst(argtypes[3]) === DataType
        IOT = CC.widenconst(argtypes[2])
        (IOT <: ShowStream || IOT <: Base.GenericIOBuffer) && return redirect(interp, show_type_value, Any[], 2, arginfo, si, vtypes, sv)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# `x.name = v` that Julia did not inline (`setproperty!(x, :name, v)`: a combination of a receiver and a value that the program does not make, but that a union of both has, where the conversion of `v` to the type of the
# field has no method, or is large) is a call of the one method of `setproperty!`, which has the name as a value, and finds the type of the field and sets it with calls of the runtime (`fieldtype`, `setfield!`): the name is a
# constant at the call, and not in the method that is compiled for it. Where the value is of the type of the field the call is the `setfield!`, and where `convert` has no method for it the call is the error that it gives.
const SETPROPERTY_SIG = Tuple{typeof(Base.setproperty!),Any,Symbol,Any}

function expand_setproperty!(ir::CC.IRCode)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :invoke && length(st.args) == 5 || continue
        mi = st.args[1]
        mi isa Core.CodeInstance && (mi = mi.def)
        mi isa Core.MethodInstance && mi.def isa Method && mi.def.sig === SETPROPERTY_SIG || continue
        name = CC.argextype(st.args[4], ir)
        name isa Core.Const && name.val isa Symbol || continue
        T = CC.widenconst(CC.argextype(st.args[3], ir))
        (T isa DataType && isconcretetype(T) && isstructtype(T) && !(T <: Type) && hasfield(T, name.val)) || continue
        V = CC.widenconst(CC.argextype(st.args[5], ir))
        isconcretetype(V) || continue
        FT = fieldtype(T, name.val)
        if V <: FT
            ir.stmts[pc][:stmt] = Expr(:call, Core.setfield!, st.args[3], QuoteNode(name.val), st.args[5])
        elseif FT isa DataType && isempty(methods(convert, Tuple{Type{FT},V}))
            ir.stmts[pc][:stmt] = Expr(:call, Core.throw_methoderror, Base.convert, FT, st.args[5])
        end
    end
    return ir
end

## `NamedTuple`s made of values of the type `Any`
#
# `(; label, value)` with a `value` of the type `Any` is made of a tuple, and the type of the `NamedTuple` is made of the type of the tuple: `typeof(tuple)`, which is the type of the values that the
# tuple has when the program runs. An executable has no way to make that type (the tuple is `jl_f_tuple`, the type `jl_f_apply_type`). The type that inference gives the tuple (`Tuple{Symbol,Any}`)
# is the one that the `NamedTuple` has when it is stored where it has that type (as in a `Vector` of them), and that is what a program can have: the type of the tuple is taken to be that.
function concretize_namedtuples!(ir::CC.IRCode)
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) == 4 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) === Core.apply_type || continue
        CC.singleton_type(CC.argextype(st.args[2], ir)) === NamedTuple || continue
        names = CC.argextype(st.args[3], ir)
        names isa Core.Const && names.val isa Tuple{Vararg{Symbol}} || continue
        tt = st.args[4]
        tt isa Core.SSAValue || continue
        tst = ir.stmts[tt.id][:stmt]
        tst isa Expr && tst.head === :call && length(tst.args) == 2 || continue
        CC.singleton_type(CC.argextype(tst.args[1], ir)) === Core.typeof || continue
        T = CC.widenconst(CC.argextype(tst.args[2], ir))
        T isa DataType && T <: Tuple && !isconcretetype(T) && !(T isa UnionAll) && length(T.parameters) == length(names.val) || continue
        any(p -> p isa Core.TypeVar || p isa Core.TypeofVararg, T.parameters) && continue
        N = NamedTuple{names.val,T}
        isconcretetype(N) || continue
        ir.stmts[tt.id][:stmt] = T
        ir.stmts[tt.id][:type] = Core.Const(T)
        ir.stmts[pc][:stmt] = N
        ir.stmts[pc][:type] = Core.Const(N)
        changed = true
    end
    changed || return ir
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :new && st.args[1] isa Core.SSAValue || continue
        t = ir.stmts[st.args[1].id][:type]
        t isa Core.Const && t.val isa DataType && t.val <: NamedTuple || continue
        ir.stmts[pc][:type] = t.val
    end
    return CC.compact!(ir)
end

## Tuples that have a `Union` as an element
#
# `Tuple{Union{Vector{Float64},Vector{ComplexF64}},Int}` is not a concrete type, so Julia builds such a tuple with `jl_f_tuple`, which gives it the type of the values that it is made of when the program runs:
# an executable has no way to make that type. When the function that makes the tuple is inlined the tuple is not made at all (its elements are separate values, each of them a `Union`). Julia inlines
# a function that returns such a tuple for a bonus on the size that is allowed (`inline_tupleret_bonus`, 400 in Julia). The bonus here is 10 times that, which is more than enough for `eigs` of Graphs.jl.

CC.OptimizationParams(interp::OverridesInterpreter) = CC.OptimizationParams(interp.opt_params; inline_tupleret_bonus = 4_000)

## `fma`
#
# `Core.Intrinsics.have_fma(T)` (which `fma`, `muladd`'s `Float64` method, `log`, `^`, `two_mul`, ... ask) is answered when the code is made, from the features that the function that it is in has, and the
# functions of a program do not have them (the target machine does, but not the attribute of the function): the answer is then no, and `fma` is made by software, in many times the time that it takes. The program is made for
# the machine that makes it, and that is the machine that Julia asked: it is that answer that is used.
function CC.abstract_call_known(interp::OverridesInterpreter, f::Core.IntrinsicFunction, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if f === Core.Intrinsics.have_fma && length(arginfo.argtypes) == 2
        t = arginfo.argtypes[2]
        T = t isa Core.Const ? t.val : (t isa DataType && t <: Type && t.parameters[1] isa DataType ? t.parameters[1] : nothing)
        if T isa DataType && T in (Float16, Float32, Float64)
            return CC.Future(CC.CallMeta(Core.Const(Core.Intrinsics.have_fma(T)), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end
