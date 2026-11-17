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
`Nothing`, `Missing`, `Vector{Any}`), and these. For example `add_dispatch_candidates!(MyType, Tuple{Int,Float64})`. A value of another
type that reaches such a call is an error when the program runs (compiling says which calls were made this way). It is the same list
as that of `show` (see [`add_show_candidates!`](@ref)). Call it before compiling the code that has such values.
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
# (what the subtypes of a type are is a fact of the world, and of the limit that they are listed to: so it is kept for all compilations, by the type, the world and the limit; finding them is what takes the time)
const CLOSED_SUBTYPES = Dict{Tuple{Any,UInt,Int},Any}()
function listed_union(c::Compilation, @nospecialize(T))
    T isa DataType && isabstracttype(T) && T !== Any || return nothing
    # (the types of functions are not listed: there is one for each function and closure, and finding them all, which `subtypes(Function)` does, takes more than a minute the first time
    # in a process that has this package loaded. The functions that a call can have are the ones of closures.jl.)
    T <: Function && return nothing
    limit = c.settings.dispatch_limit
    get!(CLOSED_SUBTYPES, (T, Base.get_world_counter(), limit)) do
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
        any(sig -> typeintersect(atype, sig) !== Union{}, sigs) && push!(kept, M)
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
    sigs === nothing || return any(sig -> typeintersect(atype, sig) !== Union{}, sigs)
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
            key = string(fname, "(", join(("::" * (T isa Core.TypeofVararg ? string(T) : string(CC.widenconst(T))) for T in original[2:end]), ", "), ")")
            calls = c.dispatch.registered_calls
            calls[key] = get(calls, key, 0) + 1
            note_dispatch_used!(c)
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
            if ((T isa DataType && isabstracttype(T)) || unknown_parameters_of_program(T)) && !(T <: Function) && !(T <: Type)
                note_dispatch_used!(c)
                break
            end
        end
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
    calls = sort!(collect(keys(registered)))
    empty!(registered)
    shown = join(("`$c`" for c in first(calls, 5)), ", ") * (length(calls) > 5 ? ", and $(length(calls) - 5) more" : "")
    @debug "Dispatch on `Any` or on an abstract type with unlisted subtypes was resolved over registered types: a value of another type that reaches such a call aborts the program with a MethodError. Add types with `add_dispatch_candidates!`." calls = shown candidates = join(string.(c.registered.dispatch), ", ") _id = :static_dispatch_candidates
end

## `invokelatest`
#
# `invokelatest(f, args...)` calls `f` in the newest world, and so the compiler can't know what it calls: the call is an `Any`, made
# by the runtime. In a program that is compiled there are no newer methods, so it is the call `f(args...)`. Packages use it in the
# macros of logging (`@warn`), and sometimes to avoid a recursion that inference gives up on. So (for what is compiled with our method
# table) inference takes it for the call of `f`, and the statement is made that call before it is optimized.

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.invokelatest), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 2
        inner = CC.ArgInfo(arginfo.fargs === nothing ? nothing : arginfo.fargs[2:end], arginfo.argtypes[2:end])
        return CC.abstract_call(interp, inner, si, vtypes, sv)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
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

# (before optimizing: the statements of `invokelatest` are the calls that inference took them for)
function CC.optimize(interp::OverridesInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
    code = opt.src.code
    c = compilation()
    note_functions_of!(c.closures, code, opt.src.ssavaluetypes, caller.linfo) # (the functions that the code has: see closures.jl)
    caller.linfo isa Core.MethodInstance && learn_boxes!(c.boxes, opt.src, caller.linfo) # (the types of the boxes of the code: see boxes.jl)
    for pc in eachindex(code)
        # (the keywords of a call that has a type as a value are a constant of the type that has the type as the type of the field: see `typed_keywords`)
        t = opt.src.ssavaluetypes[pc]
        t isa CC.Const && has_type_values(t.val) && (opt.src.ssavaluetypes[pc] = CC.Const(typed_constant(t.val)))
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
        replacement = if called === Core.invokelatest
            Expr(:call, call.args[2:end]...)
        elseif called === call_callback && length(call.args) >= 3
            # (`call_callback(T, f, args...)` is `f(args...)`, or no call at all where no function was registered for `T`: see closures.jl)
            opt.src.ssavaluetypes[pc] === Union{} ? Expr(:call, Core.throw, "a callback that was not registered") : Expr(:call, call.args[3:end]...)
        else
            continue
        end
        assigned ? (st.args[2] = replacement) : (code[pc] = replacement)
    end
    if trace_on()
        c.closures.optimized += 1
        push!(c.closures.optimized_unique, caller.linfo)
        started = time_ns()
        result = @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
        note_slow_optimization!(c.closures, caller.linfo, (time_ns() - started) / 1e9, length(code))
        return result
    end
    return @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
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

function CC.finishopt!(interp::OverridesInterpreter, opt::CC.OptimizationState, ir::CC.IRCode)
    c = compilation()
    ir = assert_assumed_returns!(c, ir, opt.linfo)
    (c.settings.check_types || !isempty(c.registered.fields) || !isempty(c.registered.embedded)) && (ir = check_slot_reads!(c, ir))
    ir = assert_field_receivers!(ir)
    expand_dynamic_getfield!(ir)
    ir = expand_setproperty!(ir)
    trace_method_errors_on() && trace_method_errors(ir, opt.linfo)
    trace_on() && trace_noreturn(ir, opt.linfo)
    ir = concretize_namedtuples!(ir)
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
        slot_read_type(c, key) === nothing && continue
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

# `getfield(x, name)` of a struct, with a `name` that is not a constant, is `jl_f_getfield` too, and the type of what it gives depends on `name` (see `struct_field`, which is a comparison with each name):
# the call is replaced by an `invoke` of it.
function expand_dynamic_getfield!(ir::CC.IRCode)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && 3 <= length(st.args) <= 4 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) === Core.getfield || continue
        name = CC.argextype(st.args[3], ir)
        name isa Core.Const && continue
        kind = CC.widenconst(name)
        (kind === Symbol || kind === Int) || continue
        T = CC.widenconst(CC.argextype(st.args[2], ir))
        (T isa DataType && isconcretetype(T) && !(T <: Type) && T !== DataType && T !== Module &&
         Base.datatype_fieldcount(T) isa Int && 0 < Base.datatype_fieldcount(T) <= 64) || continue
        if kind === Symbol
            T <: Tuple && continue
            mi = CC.specialize_method(only(methods(struct_field)), Tuple{typeof(struct_field),T,Symbol}, Core.svec())
            ir.stmts[pc][:stmt] = Expr(:invoke, mi, struct_field, st.args[2], st.args[3])
        else
            mi = CC.specialize_method(only(methods(index_field)), Tuple{typeof(index_field),T,Int}, Core.svec())
            ir.stmts[pc][:stmt] = Expr(:invoke, mi, index_field, st.args[2], st.args[3])
        end
    end
    return ir
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
