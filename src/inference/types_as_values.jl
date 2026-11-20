# Types as values: slots that hold types (`Vector{Type}`, `Dict{Symbol,DataType}`), and what is done with what is read
# from them. A type that is a value (`DataType`) has no known type parameter, so a call on it is a dynamic dispatch. The
# types that such a slot holds are found as for any slot (slots.jl); a read of it is checked to be one of them
# (`type_slot_get`), and calls on it are split over them. Keyword arguments that are types are given exact types too.

# A slot declared `Type` (or `Type{<:Number}`) holds the types that the program stores in it, each known exactly
# (`Type{Int}`): a read is a union of a few, which Julia splits calls over.
type_value_parameter(@nospecialize(T)) = try Base.type_parameter(T) catch; nothing end # (it has none for a `Type{X}` whose `X` is a type with a free variable: `nothing`)

exact_type_value(@nospecialize(T)) = (T isa Core.TypeEq || T isa Core.TypeEgal) && (p = type_value_parameter(T); p isa Type && !CC.has_free_typevars(p))

# (not `DataType`, `UnionAll` or `Union`, which are concrete: what they hold is any type, as before, and they are in
# much of the code, where making them slots would make the slots of every program be looked at)
type_value_slot(@nospecialize(T)) = T isa Type && T !== Union{} && T <: Type && !isconcretetype(T) && !all(exact_type_value, Base.uniontypes(T))

# what is stored in a slot that holds types as values: the types that are known (`Type{Int}`), and `Type` for those that
# are not (the slot is given up)
function stored_in_type_slot(@nospecialize(T))
    T isa Union && return Union{(stored_in_type_slot(t) for t in Base.uniontypes(T))...}
    # (a type that is known is `Core.TypeEgal{X}`, as inference has it where it makes a union of types: the code that is
    # made over them, `show` of a type and the like, takes those)
    exact_type_value(T) && return Core.TypeEgal{type_value_parameter(T)}
    if T isa DataType && T <: Tuple && !isempty(T.parameters) && !any(p -> p isa Core.TypeofVararg || p isa TypeVar, T.parameters)
        return Tuple{(stored_in_type_slot(p) for p in T.parameters)...}
    end
    return T !== Union{} && T <: Type ? Type : T # (a type that is not known: `Type`, which is not a type that is closed, and gives the slot up)
end

# a tuple type that has `Type{X}` as an element (see `value_type_of`) as it is for a slot that does not hold types as
# values: `DataType` (or `UnionAll`, `Union`) for the element
function widen_tuple_type_values(@nospecialize(T))
    mentions_type_value(T) || return T # (most stores: no type is made)
    T isa Union && return Union{(widen_tuple_type_values(t) for t in Base.uniontypes(T))...}
    if T isa DataType && T <: Tuple && !isempty(T.parameters) && !any(p -> p isa Core.TypeofVararg || p isa TypeVar, T.parameters)
        return Tuple{(exact_type_value(p) ? typeof(type_value_parameter(p)) : widen_tuple_type_values(p) for p in T.parameters)...}
    end
    return T
end

# the types that are the members of `U` that are types that are known, and the elements of its tuples that are
function collect_type_values!(found::Vector{Any}, @nospecialize(U))
    for m in Base.uniontypes(U)
        if exact_type_value(m)
            push!(found, type_value_parameter(m))
        elseif m isa DataType && m <: Tuple
            for p in m.parameters
                p isa Type && collect_type_values!(found, p)
            end
        end
    end
    return found
end

# whether a slot of this declared type holds types as values: `Type`, or a tuple that has such an element
# (`Tuple{Type,Type}`)
type_value_declared(@nospecialize(T)) = type_value_slot(T) || (T isa DataType && T <: Tuple && any(p -> p isa Type && type_value_declared(p), T.parameters))

# the union of `Type{X}` for the types `X` that the slots of types hold, that are of the type `T` (`DataType`,
# `Type{<:AbstractFunction}`), or `nothing` if there are none, or too many
function type_values_union(c::Compilation, @nospecialize(T))
    found = Any[Core.TypeEgal{X} for X in c.slots.type_values if X isa T]
    (isempty(found) || length(found) > c.settings.split_limit) && return nothing
    return Union{found...}
end

## What is read from a slot of types

# A read of a slot of types (`Vector{Type}`, a field of type `Type`) has the types stored in it (`Union{Type{Int},
# Type{Float64}}`), and is checked like every slot read. It is made a call of `type_slot_get` (or `type_slot_field`),
# which inference takes the read for and the optimizer calls (the type passed as a `Val`, since a generated function is
# made for argument types), and which gives the value as a constant: `v === Int ? Int : v === Float64 ? Float64 : error`.
# (Testing a union of types with `isa` would be a runtime call for `Type{X}`.)
mentions_type_value(@nospecialize(T)) = any(m -> exact_type_value(m) || (m isa DataType && m <: Tuple && any(p -> p isa Type && mentions_type_value(p), m.parameters)), Base.uniontypes(T))

# The members of `U` as a tuple of `Val`s (generated from the type alone: the checked value's type, `Type`, is not
# concrete), and for each, whether the value is it and what it then is: a type is itself (a constant); tuples and concrete
# values are as the reading code was inferred with.
@generated members(::Val{U}) where {U} = Expr(:tuple, (:(Val{$(QuoteNode(m))}()) for m in Base.uniontypes(U))...)

@inline matches_any(v, ::Tuple{}) = false

@inline matches_any(v, ms::Tuple) = matches_member(v, first(ms)) | matches_any(v, Base.tail(ms))

@inline value_any(v, ::Tuple{}) = Core.throw("a type that was stored in a slot of types was not found when compiling")

@inline value_any(v, ms::Tuple) = matches_member(v, first(ms)) ? member_value(v, first(ms)) : value_any(v, Base.tail(ms))

# the type `X` of `Type{X}` (a generator, which is run when compiling)
@generated type_value_constant(::Val{M}) where {M} = QuoteNode(type_value_parameter(M))

@inline matches_member(v, ::Val{M}) where {M} = (M isa Core.TypeEq || M isa Core.TypeEgal) ? v === type_value_constant(Val{M}()) : (M <: Tuple && !isconcretetype(M)) ? matches_tuple(v, Val{M}()) : Core.isa(v, M)

@inline member_value(v, ::Val{M}) where {M} = (M isa Core.TypeEq || M isa Core.TypeEgal) ? type_value_constant(Val{M}()) : (M <: Tuple && !isconcretetype(M)) ? Core.typeassert(v, concrete_tuple_type(Val{M}())) : Core.typeassert(v, M)

# the type that a tuple of the type `M` (which has types as elements) is: `Tuple{DataType,Float64}` for
# `Tuple{Union{Type{Int},Type{Float64}},Float64}`; and `M` if it is not known (see `concretize_type_tuples!`)
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

# whether each element of a tuple (of the type that it is, a concrete one: `Tuple{DataType,Float64}`, which a generator
# can be made for, and which has its elements read with the index known) is one of the types that the element can be
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

# the call that the statement was taken for (by `type_slot_get` or `type_slot_field`), as the function and the type that
# is checked, or `nothing`
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

## Tests of what a type is

# `isa(x, Type{Int})` (what a call over the types that a value can be is made of: a union of `Type{X}`, and Julia tests
# the value against each member) is a call of the runtime, which looks at what `Type{Int}` is: for a type that is one
# type it is `x === Int`, and for a union of them the tests that are or-ed.
function type_value_test(ir::CC.IRCode, @nospecialize(operand))
    t = CC.argextype(operand, ir)
    t isa CC.Const && t.val isa Type || return nothing
    U = t.val
    all(exact_type_value, Base.uniontypes(U)) || return nothing
    return U
end

# the bounds `(lower, upper)` of what `isa` tests against, if it is `Type{T} where lb<:T<:ub` (a method that takes
# `Type{<:S}`), or `nothing`
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

# A tuple of types (`(Int, Float64)`, read from a slot) has the type `Tuple{DataType,DataType}`, which code can make; the
# known type `Tuple{Type,Type}` is the type of no tuple, so building one would be a runtime call. Where each element is a
# type or one of a few, all of the same kind, the tuple is made as `Tuple{DataType,...}`. `type_kinds` gives the kinds
# (`DataType` for `Int`, `UnionAll` for `Vector`) that an operand can be, through unions and `φ` nodes, or `nothing`.
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
            # (an element of a tuple of types, of the type that the code has for it (`Tuple{Type,Type}`, which no tuple is): the
            # elements of every tuple of types are references, so it is read as `Tuple{DataType,DataType}` is, with a load)
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

## Keywords that are types

# Keywords with a type as a value (`f(x; canvas = AsciiCanvas)`) are a constant `@NamedTuple{canvas::DataType}`: the
# method is compiled for any type, and what it does with it dispatches. The keywords are given the type with the exact
# type as its field type (`@NamedTuple{canvas::Type{AsciiCanvas}}`), for inference (here) and in the code (`typed_constant`,
# used by `optimize`).
function typed_namedtuple_type(nt::NamedTuple)
    types = Any[v isa Type ? Core.Typeof(v) : typeof(v) for v in values(nt)]
    return NamedTuple{keys(nt), Tuple{types...}}
end

has_type_values(@nospecialize(nt)) = nt isa NamedTuple && any(v -> v isa Type, values(nt))

typed_constant(nt::NamedTuple) = typed_namedtuple_type(nt)(values(nt))

function typed_keywords(interp, @nospecialize(kw))
    kw isa CC.Const && has_type_values(kw.val) || return nothing
    nt = kw.val
    return CC.PartialStruct(CC.typeinf_lattice(interp), typed_namedtuple_type(nt), Any[CC.Const(v) for v in values(nt)])
end

# `NamedTuple{names}(args)` gets the type `typeof(args)`, of the tuple's value: with an element of a union type
# (`Tuple{Union{UInt32,Missing}}`, from keywords or `merge`) the result's type is not known, and what is done with it needs
# the runtime. Here the `NamedTuple` gets the argument's declared type, with the union as its field type. Calls with a
# constant argument are left to Julia, and so are calls on `Any` or on a union of many types, which are split as Julia
# splits them. (Unlike Julia, `typeof` then says `@NamedTuple{a::Union{Int64,Float64}}` instead of `@NamedTuple{a::Float64}`;
# the alternative is a runtime call.)
function CC.abstract_call_known(interp::OverridesInterpreter, f::Type{<:NamedTuple}, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) == 2 && f isa UnionAll && f.body isa DataType && f.body.name === Base.typename(NamedTuple) && f.body.parameters[1] isa Tuple
        arg = arginfo.argtypes[2]
        t = CC.widenconst(arg)
        if !(arg isa CC.Const) && t isa DataType && t <: Tuple && !Base.isvatuple(t) && !isconcretetype(t) && length(t.parameters) == length(f.body.parameters[1]) &&
           all(P -> isconcretetype(P) || P isa Core.TypeEq || (P isa Union && length(Base.uniontypes(P)) <= 4 && all(isconcretetype, Base.uniontypes(P))), t.parameters)
            full = NamedTuple{f.body.parameters[1], t}
            argtypes = Any[CC.Const(full), arg]
            return CC.abstract_call_known(interp, full, CC.ArgInfo(arginfo.fargs, argtypes), si, vtypes, sv, max_methods)
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end
