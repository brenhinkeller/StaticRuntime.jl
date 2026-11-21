# Tuples and types of a few kinds: a call that Julia would leave to the runtime because an argument is one of a few
# types (`Vector{T}` of a `T` that is one of a few types, a tuple that is one of a few tuples, the element of a tuple by
# an index that is not known, a splat of a tuple of unknown length) is split into one call for each case.

## A type made of a type that is one of a few

# `ObjectiveFunction{F}()` where `F` is one of a few types (MathOptInterface's objective types) is `Core.apply_type`,
# which needs the runtime. The answer is one of a few types too: the call is inferred as `split_apply_type`, split over
# the union with a constant type in each case, and written into the code (redirect.jl).
split_apply_type(::Type{F}, ::Type{A}) where {F,A} = F{A}

split_apply_type(::Type{F}, ::Type{A}, ::Type{B}) where {F,A,B} = F{A,B}

split_apply_type(::Type{F}, ::Type{A}, ::Type{B}, ::Type{C}) where {F,A,B,C} = F{A,B,C}

# whether the type of an argument of `apply_type` is one type that is known (`Type{X}`, or a constant type), or a union
# of a few such (`Type{X}` is a `Core.TypeEq`, and in what inference has, a `Core.TypeEgal{X}`, which is a subtype of
# it)
exact_type_argument(@nospecialize(t)) = (t isa CC.Const && t.val isa Type) ||
    ((t isa Core.TypeEq || t isa Core.TypeEgal) && (p = try Base.type_parameter(t) catch; nothing end; p isa Type && !CC.has_free_typevars(p)))

function few_types_argument(@nospecialize(t))
    t isa Union || return false
    members = Base.uniontypes(t)
    # (up to 16: a type that is read from a `Vector{Type}` is one of all the types that the program stores in one, which
    # the slot of all of them has)
    return length(members) <= 16 && all(exact_type_argument, members)
end

# the union of the types that `apply_type` makes from arguments that are each a type or a union of a few
# (`Union{Type{Vector{Int}},Type{Vector{Float64}}}`), or `nothing` if there are too many, or one can not be made
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
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if 3 <= length(argtypes) <= 5 && exact_type_argument(argtypes[2]) && any(few_types_argument, argtypes[3:end]) &&
       all(t -> exact_type_argument(t) || few_types_argument(t), argtypes[3:end])
        # (what the call gives is one of the types that it makes, each a type that is known: what inference makes of the
        # cases is a merge of constants, which is a union of at most three of them, and then `Type{<:Vector}`, which a
        # call on it is not made over the cases of)
        T = applied_types(argtypes)
        return redirect(interp, split_apply_type, Any[], 2, arginfo, si, vtypes, sv; then = T === nothing ? nothing : result_of_type, with = T)
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

## Tuples of a few kinds

# A tuple with an element of a few types (`Tuple{Union{A,B},C}`, the pair of what two observables hold) is not a type
# that values have: each value is one of its cases, and Julia builds and reads it with the runtime (`jl_f_tuple`,
# `jl_get_nth_field_checked`). `Core.tuple` of such an argument, and `getfield` of such a tuple, are inferred as calls of
# `split_tuple` and `split_getfield`, split over the cases, and written into the code (redirect.jl).
for n in 1:16 # (a method for each number of elements: a method of any number of them has a `Vararg` in its signature, which the code that looks at the calls of methods takes as a type)
    xs = [Symbol(:x, i) for i in 1:n]
    @eval split_tuple($(xs...)) = ($(xs...),)
end

split_getfield(t::Tuple, i::Int) = getfield(t, i)

# the tuple types that a tuple type of a few cases is made of (`Tuple{Union{A,B},C}`: `Tuple{A,C}` and `Tuple{B,C}`),
# each a type that values have, or `nothing`
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
        # (a loop, and not a comprehension: its closure would have the types that it takes, and be a method that Julia
        # compiles for each)
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
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) >= 2 && !any(a -> a isa Core.TypeofVararg, argtypes) && any(a -> (T = CC.widenconst(a); T isa Union && element_cases(T, compilation().settings.split_limit) !== nothing), argtypes[2:end])
        T = Tuple{(CC.widenconst(a) for a in argtypes[2:end])...}
        cases = tuple_cases(T, compilation().settings.split_limit)
        if !(cases === nothing || length(argtypes) > 17)
            # (what the call gives is the tuple that `Core.tuple` gives, `Tuple{Union{A,B},C}` or one made of what is
            # known of the arguments: what inference makes of the cases is a merge of them, which is `Tuple{Any,C}` for
            # more than a few, where Julia has the union)
            rt = CC.tuple_tfunc(CC.typeinf_lattice(interp), argtypes[2:end])
            return redirect(interp, split_tuple, Any[], 2, arginfo, si, vtypes, sv; then = result_split, with = rt)
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# (the read of an element of a tuple of a few cases, by an index that is a constant: the call of `split_getfield` on the
# union of the cases, or `nothing`)
function split_tuple_read(interp, arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv)
    argtypes = arginfo.argtypes
    length(argtypes) == 3 || return nothing
    (argtypes[3] isa Core.Const && argtypes[3].val isa Int) || return nothing
    T = CC.widenconst(argtypes[2])
    (T isa Union || (T isa DataType && T <: Tuple)) && !isconcretetype(T) || return nothing
    cases = tuple_cases(T, compilation().settings.split_limit)
    (cases === nothing || length(cases) < 2) && return nothing
    # (what is read is what `getfield` gives, as for `split_tuple` above: the union of what the cases give, which
    # inference merges)
    rt = CC.getfield_tfunc(CC.typeinf_lattice(interp), argtypes[2], argtypes[3])
    return redirect(interp, split_getfield, Any[], 2, arginfo, si, vtypes, sv; argtypes = Any[Union{cases...}, argtypes[3]], then = result_split, with = rt)
end

result_split(result::CC.CallMeta, @nospecialize(rt)) = result.rt === Union{} ? result : CC.CallMeta(split_result(result.rt, rt), result.exct, result.effects, result.info, result.refinements)

# (what a split call gives: the merge of its cases where that is the union of them, which a call on it is made over the
# cases of, `Union{Tuple{A,C},Tuple{B,C}}`; else what the builtin gives, `Tuple{Union{A,B},C}`, as inference merges more
# than a few tuples into one of `Any`)
function split_result(@nospecialize(merged), @nospecialize(builtin))
    T = CC.widenconst(merged)
    return (T isa Union && all(isconcretetype, Base.uniontypes(T))) || isconcretetype(T) ? merged : builtin
end

# the type of `t[i]` for a tuple `t` that is a constant with a type in it, and an `i::Int` that is not a constant: a
# union of the types of its elements, with `Type{x}` for each that is a type; or `nothing`
function types_of_constant_tuple(argtypes)
    length(argtypes) == 3 || return nothing
    t, i = argtypes[2], argtypes[3]
    (t isa Core.Const && t.val isa Tuple && !(i isa Core.Const) && CC.widenconst(i) === Int) || return nothing
    # (the elements by `getfield`: `any` and a generator over the tuple are methods that Julia compiles for the type of
    # each tuple that is asked about)
    v = t.val
    n = nfields(v)
    n <= SLOT_LIMIT[] || return nothing
    types = Any[]
    has_type = false
    for k in 1:n
        e = getfield(v, k)
        e isa Type && (has_type = true)
        push!(types, e isa Type ? Core.TypeEgal{e} : typeof(e))
    end
    has_type || return nothing
    return Union{types...}
end

## Fields by a name or an index that is not known

# `getfield(x, name)` of a struct by a name that is not a constant is `jl_f_getfield` too, with a type that depends on
# `name`: it is made a call of `struct_field`, comparing with each name (`index_field` for an index; redirect.jl), or
# `nothing`. (See the `getfield` hook in boxes.jl.)
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

# `isdefined(x, name)` with a `name` that is not a constant: the call of `struct_isdefined`, the same comparisons
# (`get(f, nt, name)` and `haskey(nt, name)` of a `NamedTuple` are that)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.isdefined), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 3 && !(argtypes[3] isa Core.Const) && CC.widenconst(argtypes[3]) === Symbol
        T = CC.widenconst(argtypes[2])
        if T isa DataType && isconcretetype(T) && isstructtype(T) && !(T <: Type) && !(T <: Tuple) && T !== Module && Base.datatype_fieldcount(T) isa Int && Base.datatype_fieldcount(T) <= 64
            return redirect(interp, struct_isdefined, Any[], 2, arginfo, si, vtypes, sv)
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# `fieldtype(T, i)` of a type that is known, by an index or a name that is not: Julia compiles it as a read of the field
# types of the type object (`T.types[i]`), which a type in the binary does not have (`field_cut`: a list of `nothing`s
# of that length, so that the read would give a wrong answer, silently). It is made a call of `static_fieldtype`, which
# compares the index or the name with each field's, each branch a constant type. (`fieldtype` of a type that is not
# known is a call of the runtime, `jl_f_fieldtype`, which is refused.)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.fieldtype), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if 3 <= length(argtypes) <= 4 && argtypes[2] isa Core.Const && !(argtypes[3] isa Core.Const)
        T = argtypes[2].val
        kind = CC.widenconst(argtypes[3])
        if T isa DataType && !isabstracttype(T) && Base.datatype_fieldcount(T) isa Int && Base.datatype_fieldcount(T) <= 64 &&
           (kind === Int || kind === Symbol)
            return redirect(interp, static_fieldtype, Any[Val(T)], 3, arginfo, si, vtypes, sv; to = 3)
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

@generated function static_fieldtype(::Val{T}, i::Int) where {T}
    body = Expr(:block)
    for k in 1:fieldcount(T)
        push!(body.args, :(i == $k && return $(QuoteNode(fieldtype(T, k)))))
    end
    push!(body.args, :(throw(BoundsError($T, i))))
    return body
end
@generated function static_fieldtype(::Val{T}, name::Symbol) where {T}
    body = Expr(:block)
    for k in 1:fieldcount(T)
        push!(body.args, :(name === $(QuoteNode(fieldname(T, k))) && return $(QuoteNode(fieldtype(T, k)))))
    end
    push!(body.args, :(throw(FieldError($T, name))))
    return body
end

## Splats

# A vector literal with a splat of something that is not a tuple: the call of `splat_vector` with the parts, where Julia
# would call the runtime. Left to Julia where it knows each part's length (tuples, or a static vector whose elements it
# iterates), as its call info says (an `ApplyCallInfo` with the iteration of each non-tuple part).
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core._apply_iterate), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    plan = splat_plan(arginfo.argtypes)
    plan === nothing && return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
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

# (the arguments of `redirect` for the splat: `splat_vector(Val(T), Val(skip), parts...)`, or `nothing` for a call that
# is not a vector literal, has only tuples, or whose type depends on more than the types)
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
