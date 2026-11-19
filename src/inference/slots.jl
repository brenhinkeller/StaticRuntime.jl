# Slots that hold values of an abstract type: what is stored in them.
#
# The elements of a `Vector{Any}`, and the fields of a struct that are of the type `Any` or an abstract type, hold values of types that inference does not know, so what is read from them is an `Any`, and a call
# on it is made over the *registered* types (see dispatch.jl): a value of another type aborts the program. The types that the slot holds are the types of what the program stores in it, all of which are in the code that
# is compiled (and in the constants that it refers to): `Any[1, "a", (2, 3.5)]` holds an `Int`, a `String` and a `Tuple{Int,Float64}`. This finds them, and says what it found (it does not change what is compiled yet).
#
# A slot is the elements of one type of memory (`Memory{Any}`: all the `Vector{Any}` and the `Dict{K,Any}` of the program are one), or the field of a struct (`RefValue{Any}.x`, a field of the type `Any` of a struct of
# the program). The key of a slot is `(:elem, T, nothing)` or `(:field, S, name)`.

# (`SlotKey` is in registry.jl.) What a compilation knows of its slots is its `SlotState` (compilation.jl): `seen`, the types that were stored in each slot in this pass: the union of them, or `Any` when something of a type
# that is not known was (so that what the slot holds is not known); `types`, the types that reads of each slot are given in this pass (see `update_slot_types!`); `open`, the slots that are given up (what is stored in them is
# not known: a read of one is an `Any`, over the registered types); `seen_unknown`, the slots that something of a type that is not known was stored in, in this pass. `mode` is `:on` (the types are used), `:observe` (found and
# kept in `seen`, and not used), or `:off`.
const SLOT_PASS_LIMIT = 8
# Every read of a slot that was given the types that were stored in it is checked (`check_slot_reads!`, dispatch.jl): the program stops if the value is of another type, as it would be if a store were missed. It is on when the compilation is `strict` (the default), and `STATIC_RUNTIME_CHECK_TYPES=0` turns it off (`1` turns it on for `strict = false`); it costs nothing that could be measured in the benchmarks of `bench/dispatch.jl` (see `Settings`)
const SLOT_LIMIT = Ref(64) # the most types that a slot holds before it is given up
# the number of the types of the universe that a compilation adds (the types of a program that is compiled: more are not added, so that what is found settles)
const UNIVERSE_LIMIT = 512

# Whether this compilation has called anything over the registered types (a value of the type `Any` that it dispatched on): when it has not, there is nothing that the types of the slots would change.
# What was inferred before is taken from the cache, where this is not seen again: so it is kept with what is inferred (`SlotFactsResult`, of the `CodeInstance` of the method that made the call), and the methods that the
# program reaches are asked (`dispatch_was_used`). Nothing is kept in a table that a compilation changes: what a compilation finds is its own, and what is in the cache is what inference of a method made of it.
function note_dispatch_used!(c::Compilation, sv = nothing)
    c.dispatch.registered_used = true
    # (the method whose code made the call: for the inference that is of the method as it is called with any arguments, and not of the one that is made for the constants that a call has, which is not kept: see `record_slot_facts!`)
    if sv isa CC.InferenceState && sv.result.overridden_by_const === nothing
        push!(c.dispatch.used_in, sv.linfo)
    end
    return
end

# whether the program that is reached from `root` has a call over the registered types: this compilation made one, or a method that it reaches (inferred now or taken from the cache) did
function dispatch_was_used(c::Compilation, interp, root)
    c.dispatch.registered_used && return true
    used = false
    for ci in reachable_code_instances(interp, root)
        r = slot_facts_of(ci)
        r === nothing || r.dispatch_used && (used = true; break)
    end
    return used
end

# the code instances that `root` depends on, which the ones of the methods that were inlined into them are among (the edges of a method are the methods that it calls and those that were inlined into it)
function reachable_code_instances(interp, root::Core.CodeInstance)
    found = Core.CodeInstance[]
    seen = Base.IdSet{Any}()
    stack = Any[root]
    cache = CC.code_cache(interp)
    while !isempty(stack)
        x = pop!(stack)
        x in seen && continue
        push!(seen, x)
        ci = x isa Core.CodeInstance ? x : x isa Core.MethodInstance ? get(cache, x, nothing) : nothing
        ci isa Core.CodeInstance || continue
        push!(found, ci)
        for e in ci.edges
            (e isa Core.CodeInstance || e isa Core.MethodInstance) && push!(stack, e)
        end
    end
    return found
end

## The universe: the types that the program makes
#
# A call with an argument of the type `Any` is made over the types that were registered (dispatch.jl), and a value of another type that reaches it aborts the program. The values of a program are made in its code, which is what is
# compiled: a type that nothing makes is not one that a value can have. The types of the statements of the code that is reached (and of the constants that it refers to) are those that the program can make, and the ones that are not
# types of Julia itself (those that are not defined in `Core`, `Base`, the standard library or this package, or that have one of them as a parameter: `Vector{MyType}`) are added to the types that a call with an `Any` is made over, where a method fits them. The types that are
# found in a pass are the ones that are used in the next, until a pass finds no more (the types make code reached that makes others); a program that makes no such types needs no more passes than it did. `STATIC_RUNTIME_UNIVERSE=0` leaves them out.
# (The registered types that the program does not make are not left out, which was tried: the types that a first pass finds are those of a call over all the registered types, and each of those makes values of its own type, so nothing is
# left out, and the extra pass costs half of the time of compiling. A program that gets an object of a type that it does not make has a `MethodError` that says so.)

# whether a module is one of Julia's own (the standard library, Base and Core, and this package), whose types are the ones that are registered when a program is likely to have them
# (what a module is does not change: it is kept for the compilation. Outside of one, it is found each time)
function julia_owned_module(m::Module)
    c = CURRENT_COMPILATION[]
    return c === nothing ? find_julia_owned_module(m) : get!(() -> find_julia_owned_module(m), c.julia_owned, m)
end
function find_julia_owned_module(m::Module)
    root = Base.moduleroot(m)
    (root === Core || root === Base || root === StaticRuntime || root === StaticTools) && return true # (the package, and what its programs are made with)
    path = pathof(root)
    return path !== nothing && startswith(path, Sys.STDLIB)
end

# whether the objects of the concrete type `T` are not all of Julia's own types: the module that defines it is not one of Julia's, or a parameter of it is a type of that kind
function user_relevant(@nospecialize(T), depth::Int = 0)
    T isa DataType && isconcretetype(T) && depth <= 2 || return false
    T <: Function && return false # (the types of functions and closures: see closures.jl)
    T <: Type && return false
    # (`Val{X}` is a type that holds a type or a number for a method that is generated from it, not a value that the program makes: with the code not inlined, as it is under `--code-coverage`, a call of such a method with an
    # argument of the type `Val` was made over `Val{MyType}`, which the method does not take, and that was all that it was made over, so that it was a call that cannot succeed, and so was what called it)
    T <: Val && return false
    julia_owned_module(T.name.module) || return true
    for p in T.parameters
        p isa DataType && user_relevant(p, depth + 1) && return true
    end
    return false
end

function note_universe!(c::Compilation, @nospecialize(T))
    c.settings.universe || return
    T = CC.widenconst(T)
    user_relevant(T) || return
    s = c.slots
    s.facts_sink === nothing ? push!(s.universe_seen, T) : push!(s.facts_sink, ((:universe, T, nothing), Any))
    return
end

# the types of the universe that are subtypes of `T` (for the types that a call is made over)
function universe_extras(c::Compilation, @nospecialize(T))
    s = c.slots
    (c.settings.universe && !isempty(s.universe)) || return Any[]
    # (not `get!` with a closure that has `T`: a closure of each type is a method that Julia compiles)
    found = get(s.universe_extras, T, nothing)
    found === nothing || return found
    found = Any[]
    for t in s.universe
        t <: T && push!(found, t)
    end
    return s.universe_extras[T] = found
end

# the types that the statements of a method have (those of the optimized code of it, or of the code before it was optimized), and its arguments
function note_universe_statements!(c::Compilation, types, stmts, mi::Core.MethodInstance)
    c.settings.universe || return
    sig = Base.unwrap_unionall(mi.specTypes)
    sig isa DataType && for T in sig.parameters
        T isa Type && note_universe!(c, T)
    end
    for (st, T) in zip(stmts, types)
        # (a `PiNode` and a `PhiNode` have the type of values that are made elsewhere, and what a `typeassert` gives is the type of its argument: a type that is only there because a call was made over it is not one that is made)
        (st isa Core.PiNode || st isa Core.PhiNode || st isa Core.PhiCNode || st isa Core.UpsilonNode) && continue
        T isa Type || T isa Core.Const || T isa Core.PartialStruct || continue
        note_universe!(c, T)
    end
    return
end

# said when the types of the slots have changed, so that the compilation is made again with them (the pass is cut short: inference is what they are found from)
struct SlotsChanged <: Exception end

# whether what is read from a slot of the declared type `T` has a type that is not known: `Any`, an abstract type, a union with one of them. (A concrete type, and a union of them, are known already.)
needs_slot_type(@nospecialize(T)) = !(isconcretetype(T) || (T isa Union && all(isconcretetype, Base.uniontypes(T))) || (T <: Type && !type_value_slot(T)))

# Types as values (`Vector{Type}`, `Dict{Type,Int}`, a field of the type `Type`): what a slot of the declared type `Type` (or `Type{<:Number}`) holds is the types that the program stores in it, each of which is a type that is
# known, `Type{Int}`: what is read is a union of a few of them, which Julia splits a call over, with a constant in each case. A slot whose declared type is one type (`Type{Int}`) is a type that is known already.
type_value_parameter(@nospecialize(T)) = try Base.type_parameter(T) catch; nothing end # (it has none for a `Type{X}` whose `X` is a type with a free variable: `nothing`)
exact_type_value(@nospecialize(T)) = (T isa Core.TypeEq || T isa Core.TypeEgal) && (p = type_value_parameter(T); p isa Type && !CC.has_free_typevars(p))
# (not `DataType`, `UnionAll` or `Union`, which are concrete: what they hold is any type, as before, and they are in much of the code, where making them slots would make the slots of every program be looked at)
type_value_slot(@nospecialize(T)) = T isa Type && T !== Union{} && T <: Type && !isconcretetype(T) && !all(exact_type_value, Base.uniontypes(T))
# the type of a value that is stored: `Type{x}` for a type (which is what is known of it), else the type of the value
stored_value_type(@nospecialize(x)) = x isa Type ? Type{x} : typeof(x)

# whether a type is one that a slot can be said to hold: concrete, or a union of them
closed_type(@nospecialize(T)) = all(closed_member, Base.uniontypes(T))
# (a concrete type, a type that is one type as a value, or a tuple of such: `Tuple{Type{Int},Float64}`)
closed_member(@nospecialize(t)) = isconcretetype(t) || exact_type_value(t) ||
    (t isa DataType && t <: Tuple && !isempty(t.parameters) && all(p -> p isa Type && closed_type(p), t.parameters))

# The type of what is stored where the type of the value is `T`: a value of a type that is `Type{...}`, or `Type`, is a type object, which is a `DataType`, a `UnionAll` or a `Union` (a type that is not concrete otherwise)
function stored_type(@nospecialize(T))
    T isa Union && return Union{(stored_type(t) for t in Base.uniontypes(T))...}
    return !isconcretetype(T) && T <: Type ? Union{DataType,UnionAll,Union} : T
end

# what is stored in a slot that holds types as values: the types that are known (`Type{Int}`), and `Type` for those that are not (the slot is given up)
function stored_in_type_slot(@nospecialize(T))
    T isa Union && return Union{(stored_in_type_slot(t) for t in Base.uniontypes(T))...}
    # (a type that is known is `Core.TypeEgal{X}`, as inference has it where it makes a union of types: the code that is made over them, `show` of a type and the like, takes those)
    exact_type_value(T) && return Core.TypeEgal{type_value_parameter(T)}
    if T isa DataType && T <: Tuple && !isempty(T.parameters) && !any(p -> p isa Core.TypeofVararg || p isa TypeVar, T.parameters)
        return Tuple{(stored_in_type_slot(p) for p in T.parameters)...}
    end
    return T !== Union{} && T <: Type ? Type : T # (a type that is not known: `Type`, which is not a type that is closed, and gives the slot up)
end

# a tuple type that has `Type{X}` as an element (see `value_type_of`) as it is for a slot that does not hold types as values: `DataType` (or `UnionAll`, `Union`) for the element
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

# whether a slot of this declared type holds types as values: `Type`, or a tuple that has such an element (`Tuple{Type,Type}`)
type_value_declared(@nospecialize(T)) = type_value_slot(T) || (T isa DataType && T <: Tuple && any(p -> p isa Type && type_value_declared(p), T.parameters))

function note_slot_store!(c::Compilation, key::SlotKey, @nospecialize(T); param::Bool = false, arg::Union{Nothing,Int} = nothing)
    s, settings = c.slots, c.settings
    if get!(() -> type_value_declared(key[1] === :elem ? key[2] : fieldtype(key[2], key[3])), s.holds_types, key)
        T = stored_in_type_slot(T)
        # (a type that a method is given, that is stored: a method is made for the types of its arguments, which for a type that is an argument is `DataType` (`Base.__safe_setindex!(::Vector{Type}, ::DataType, ::Int)`), and the type is what the
        # caller has: the stores of the callers, which are of the types that they have, are those that are looked at. A store that is missed is found when the program runs, by the check of what is read)
        # A store of a type that is not known (`Type`, `DataType`, `Type{<:AbstractFunction}` of a method that is made for any of them, a tuple with one): what is stored in a slot of types is a type, whatever it is, and
        # the read of the slot is checked (a type that is not one of those that were found stops the program, with a message that says so). So it says nothing of the types that the slot holds, which are those of the
        # stores that are known. Of an argument of the method, what the callers give it is what is stored: kept as a fact of the method, see `resolve_argument_stores!`.
        if !closed_type(T)
            param && arg !== nothing && s.facts_sink !== nothing && s.fact_mi !== nothing && push!(s.facts_sink, ((:argstore, (s.fact_mi, arg), nothing), key))
            return
        end
    else
        T = stored_type(widen_tuple_type_values(T))
    end
    T === Union{} && return
    key in c.registered.embedded && !closed_type(T) && return # (see `@assume_field_embedded`: the reads are checked)
    if s.facts_sink !== nothing
        settings.why && !closed_type(T) && push!(s.unknown_census, (key, s.store_operand isa Core.Argument, context_text(s.store_context)))
        push!(s.facts_sink, (key, T))
        return
    end
    isempty(settings.blind) || (T = Union{(t for t in Base.uniontypes(T) if !(string(t) in settings.blind))...}; T === Union{} && return)
    cur = get!(s.seen, key, Union{})
    if !closed_type(T)
        push!(s.seen_unknown, key)
        if settings.why
            why = get!(Vector{String}, s.unknown_stores, key)
            length(why) < 6 && push!(why, string(T, "  in  ", context_text(s.store_context)))
        end
        return
    end
    new = Union{cur, T}
    Base.unionlen(new) > settings.slot_limit ? push!(s.seen_unknown, key) : (s.seen[key] = new)
    for t in Base.uniontypes(T)
        note_stored_type!(c, key, t)
    end
    return
end

# A type that the program stores in a slot of an abstract type is one that a value of that type can have, whoever defines it (a `Vector{Int}` or a `Tuple{Int,Float64}` in a `Vector{Any}`: the types that are made by the
# program that are not user types are not in the universe otherwise, and are not registered), so a call on a value of the type `Any` is made over it too, where the slot is one that is not known (see `note_universe!`).
# Only for a slot that is open at the end of the pass (`add_stored_types!`): a slot that has types has those for what is read from it, and the types that all the slots of a program store, as the types that a call is made over,
# are many (the program that is made of `String`s and `Symbol`s of a `Vector{Any}` has hundreds), which a call over a value that is not known is split by.
# (the types of the type system, that the code of Base keeps in a `Vector{Any}` while it works with types (`typejoin`), are not values of a program: a call that is made over them is one that is not wanted)
const REFLECTION_TYPES = Any[TypeVar, Core.TypeofVararg, Core.TypeName, Module, Method, Core.MethodInstance, Core.CodeInstance, Core.SimpleVector]
function note_stored_type!(c::Compilation, key::SlotKey, @nospecialize(T))
    c.settings.universe || return
    (T isa DataType && isconcretetype(T) && !(T <: Function) && !(T <: Type)) || return
    for R in REFLECTION_TYPES # (a loop: see `meets_any`)
        T <: R && return
    end
    T in c.registered.dispatch && return # (registered already)
    push!(get!(Set{Any}, c.slots.stored_by_slot, key), T)
    return
end

# the types that were stored in the slots that are open, as types of the universe
function add_stored_types!(c::Compilation)
    s = c.slots
    for (key, types) in s.stored_by_slot
        (key in s.open || key in s.seen_unknown) || continue
        union!(s.universe_seen, types)
    end
    return
end

# the key of the memory that a reference of the type `R` is of (`GenericMemoryRef{:not_atomic,Any,...}`), or `nothing` if what it holds is of a type that is known
function elem_slot_key(@nospecialize(R))
    R = CC.widenconst(R)
    R isa DataType && R <: Core.GenericMemoryRef && length(R.parameters) >= 2 || return nothing
    T = R.parameters[2]
    T isa Type && needs_slot_type(T) || return nothing
    return (:elem, T, nothing)
end

# the key of the field `name` (a symbol or a number) of a struct of the type `S`, or `nothing` if it is of a type that is known
function field_slot_key(@nospecialize(S), @nospecialize(name))
    S = CC.widenconst(S)
    S isa DataType && isconcretetype(S) && !(S <: Tuple) && !(S <: Type) && isstructtype(S) || return nothing
    idx = name isa Symbol ? Base.fieldindex(S, name, false) : name isa Integer ? Int(name) : 0
    1 <= idx <= fieldcount(S) || return nothing
    needs_slot_type(fieldtype(S, idx)) || return nothing
    return (:field, S, fieldname(S, idx))
end

# The type of what a lattice element is, with the types that it has as values: `widenconst` of a tuple that holds types (`(Int, 3)`) is `Tuple{DataType,Int}`, which is not the types that it has
function value_type_of(@nospecialize(t))
    if t isa CC.Const
        v = t.val
        v isa Type && return Type{v}
        v isa Tuple && any(e -> e isa Type, v) && return Tuple{(e isa Type ? Type{e} : typeof(e) for e in v)...}
    elseif t isa CC.PartialStruct && t.typ isa DataType && t.typ <: Tuple && length(t.fields) == length(t.typ.parameters) && any(f -> f isa CC.Const && f.val isa Type, t.fields)
        return Tuple{(value_type_of(f) for f in t.fields)...}
    end
    return CC.widenconst(t)
end

# the type of an operand of a statement of optimized code, where the arguments are those of the specialization of the method
function slot_operand_type(src::Core.CodeInfo, mi::Core.MethodInstance, x)
    x isa Type && return Type{x} # (a type that the code has as a value: `Type{Int}`, not `DataType`)
    x isa QuoteNode && x.value isa Type && return Type{x.value}
    if x isa GlobalRef || x isa Core.BindingPartition
        v = constant_operand(x) # (the code refers to a global through its binding partition: a constant that is a type)
        v isa Type && return Type{v}
    end
    if x isa Core.SSAValue && src.ssavaluetypes isa Vector
        T = value_type_of(src.ssavaluetypes[x.id])
        # (the type of a tuple that is made in the code, as the types that its elements have: what the optimized code has for it is `Tuple{Type,DataType}` when an element is a type)
        if T isa DataType && T <: Tuple && !isempty(T.parameters)
            st = src.code[x.id]
            st isa Expr && st.head === :(=) && length(st.args) == 2 && (st = st.args[2])
            if st isa Expr && !isconcretetype(T) && st.head === :call && length(st.args) == length(T.parameters) + 1 && called_function(src.code, st.args[1]) === Core.tuple
                return Tuple{(slot_operand_type(src, mi, a) for a in st.args[2:end])...}
            elseif st isa Expr && st.head === :new && length(st.args) == length(T.parameters) + 1 && st.args[1] === T && any(p -> p === DataType || p === UnionAll, T.parameters)
                # (a tuple of types that was made as `Tuple{DataType,...}`, see `concretize_type_tuples!`)
                return Tuple{(slot_operand_type(src, mi, a) for a in st.args[2:end])...}
            end
        end
        return T
    end
    if x isa Core.Argument
        sig = Base.unwrap_unionall(mi.specTypes)
        sig isa DataType && x.n <= length(sig.parameters) || return Any
        T = sig.parameters[x.n]
        return T isa Core.TypeofVararg ? Any : T
    end
    return operand_type(src, x)
end

# the name of a field that a statement gives as a constant, or `nothing`
const_field_name(x) = x isa QuoteNode ? x.value : (x isa Symbol || x isa Integer) ? x : nothing

# What a statement stores in the slots: `called(x)` is the function (or the type) that the operand `x` is, and `optype(x)` the type of an operand
function learn_statement!(c::Compilation, call::Expr, called, optype; precise::Bool = true, argof = x -> x isa Core.Argument ? x.n : nothing, lattice = x -> nothing,
                          pathof = x -> (k = argof(x); k === nothing ? nothing : (k, ())))
    s = c.slots
    # (`precise` is whether the types of the operands are those that inference had: the types of the statements of the optimized code are not, for a tuple that has types in it, which the facts that were kept from before the optimizer are: see `record_slot_facts!`)
    store!(key, operand) = (s.store_operand = operand; a = argof(operand); note_slot_store!(c, key, optype(operand); param = a !== nothing || !precise, arg = a))
    # `x.name = v` that is a call of `setproperty!` (not inlined, or before the inliner): a store of `v` in the field `name`, where that is known. (The method itself, which sets the field that its argument names, is not looked at: see
    # `learn_slots!`: this is how the stores that are made by it are known, with the name and the value of each call.)
    if (call.head === :call && length(call.args) == 4 && called(call.args[1]) === Base.setproperty!) ||
       (call.head === :invoke && length(call.args) == 5 && called(call.args[2]) === Base.setproperty!)
        o = call.head === :call ? 2 : 3
        name = const_field_name(call.args[o+1])
        S = optype(call.args[o])
        note_written!(c, CC.widenconst(S), name) # (see objects.jl)
        if name === nothing
            S isa DataType && isconcretetype(S) && isstructtype(S) &&
                for i in 1:fieldcount(S); needs_slot_type(fieldtype(S, i)) && note_slot_store!(c, (:field, S, fieldname(S, i)), Any); end
        else
            key = field_slot_key(S, name)
            key === nothing || store!(key, call.args[o+2])
            v = call.args[o+2]
            note_object_store!(c, CC.widenconst(S), name, lattice(call.args[o]), pathof(call.args[o]), argof(v), optype(v))
        end
        return
    end
    if call.head === :call && length(call.args) >= 3
        f = called(call.args[1])
        if f === Core.memoryrefset!
            key = elem_slot_key(optype(call.args[2]))
            key === nothing || store!(key, call.args[3])
        elseif f === Core.memoryrefswap! || f === Core.memoryrefsetonce! || f === Core.memoryrefreplace!
            # (the value that is stored: the second of the arguments after the reference for `swap` and `setonce`, the third for `replace`)
            key = elem_slot_key(optype(call.args[2]))
            i = f === Core.memoryrefreplace! ? 4 : 3
            key === nothing || (length(call.args) >= i ? store!(key, call.args[i]) : note_slot_store!(c, key, Any))
        elseif f === Core.memoryrefmodify!
            key = elem_slot_key(optype(call.args[2]))
            key === nothing || note_slot_store!(c, key, Any) # (what a function that is given gives: not followed)
        elseif f === Core.setfield! || f === Core.swapfield! || f === Core.setfieldonce! || f === Core.replacefield! || f === Core.modifyfield!
            # (the stored value: the third of the arguments after the object, the fourth for `replace`; `modify` stores what a function gives)
            i = f === Core.replacefield! ? 5 : 4
            name = const_field_name(call.args[3])
            S = optype(call.args[2])
            note_written!(c, CC.widenconst(S), name) # (see objects.jl)
            # (`stored`: whether the value is an operand. It can be the constant `nothing` itself, `x.val = nothing`, which is a store of `Nothing`: a `nothing` for "no operand" made it a store of
            # an unknown type, which opened every slot that a `nothing` is stored in, `Observable{Any}.val` of Makie's axes)
            stored = !(f === Core.modifyfield! || length(call.args) < i)
            operand = stored ? call.args[i] : nothing
            T = stored ? optype(operand) : Any
            if name === nothing
                # (a field that is not known when compiling: any of the fields that hold an unknown type may be it)
                S isa DataType && isconcretetype(S) && isstructtype(S) &&
                    for i in 1:fieldcount(S); needs_slot_type(fieldtype(S, i)) && note_slot_store!(c, (:field, S, fieldname(S, i)), Any); end
            else
                key = field_slot_key(S, name)
                key === nothing || (s.store_operand = operand; a = stored ? argof(operand) : nothing; note_slot_store!(c, key, T; param = a !== nothing || !precise, arg = a))
                note_object_store!(c, CC.widenconst(S), name, lattice(call.args[2]), pathof(call.args[2]), stored ? argof(operand) : nothing, T)
            end
        elseif f isa Core.IntrinsicFunction && nameof(f) in (:pointerset, :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace)
            # (a store through a pointer to values of an abstract type: into any memory that holds them, and any field of that type)
            P = CC.widenconst(optype(call.args[2]))
            P isa DataType && P <: Ptr && length(P.parameters) == 1 && P.parameters[1] isa Type && note_written!(c, P.parameters[1], nothing) # (a struct that is written through a pointer: any field of it)
            if P isa DataType && P <: Ptr && length(P.parameters) == 1 && P.parameters[1] isa Type && needs_slot_type(P.parameters[1])
                note_slot_store!(c, (:elem, P.parameters[1], nothing), Any)
                note_raw_store!(c, P.parameters[1])
            end
        end
    elseif call.head === :new && length(call.args) >= 2
        S = called(call.args[1])
        S isa DataType && isconcretetype(S) && isstructtype(S) && !(S <: Tuple) || return
        for (i, a) in enumerate(call.args[2:end])
            i <= fieldcount(S) || break
            needs_slot_type(fieldtype(S, i)) || continue
            store!((:field, S, fieldname(S, i)), a)
        end
    elseif call.head === :splatnew && length(call.args) >= 2
        # (`new(t...)`: the fields are the elements of the tuple)
        S = called(call.args[1])
        S isa DataType && isconcretetype(S) && isstructtype(S) && !(S <: Tuple) || return
        TT = CC.widenconst(optype(call.args[2]))
        for i in 1:fieldcount(S)
            needs_slot_type(fieldtype(S, i)) || continue
            ET = TT isa DataType && TT <: Tuple && isconcretetype(TT) && i <= length(TT.parameters) ? TT.parameters[i] : Any
            note_slot_store!(c, (:field, S, fieldname(S, i)), ET)
        end
    end
    return
end

# the stores of a method (its optimized statements, with their types)
generic_setproperty(mi::Core.MethodInstance) = mi.def isa Method && mi.def.sig === SETPROPERTY_SIG

function learn_slots!(c::Compilation, src::Core.CodeInfo, mi::Core.MethodInstance)
    generic_setproperty(mi) && return
    s = c.slots
    code = src.code
    called = x -> called_function(code, x)
    optype = x -> slot_operand_type(src, mi, x)
    for pc in eachindex(code)
        st = code[pc]
        call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
        call isa Expr || continue
        c.settings.why && (s.store_context = (mi, pc, call, src)) # (made into text only for a store that is reported: `context_text`)
        learn_statement!(c, call, called, optype; precise = false, lattice = x -> optimized_lattice(src, x))
    end
    return
end

# The stores of a method as they are before the inliner and the scalar replacement have been at it (a `Pair` that only holds the value that is read from a `Dict` for a moment is not there afterwards, and the type of its field is
# read all the same), as facts about the method that are kept, so that the method is not looked at again when it is taken from the cache. They are kept *with the result of inference of the method* (`SlotFactsResult`, in the
# `analysis_results` of the `InferenceResult`, which is those of the `CodeInstance` that is cached), and so they are what inference of that method found, for the key of the cache that it was made for, and for nothing else: no table
# that compilations change, and no facts that another program found. (A method is also inferred for the constants that a call gives it, `getproperty(x, :a)`; that is not what is cached for the method, and what it stores is
# a part of what the method stores for any arguments.)
struct SlotFactsResult
    key::Int                                  # the key of the cache that this was found for (`inference_key`)
    facts::Vector{Tuple{SlotKey,Any}}         # the stores as (slot, type), the types that the code makes, and what it refers to that is not known
    dispatch_used::Bool                       # whether the code of the method made a call over the registered types
end

# the facts that were kept with a code instance, or `nothing`
function slot_facts_of(ci::Core.CodeInstance)
    return CC.traverse_analysis_results(ci) do @nospecialize result
        result isa SlotFactsResult ? result : nothing
    end
end

function record_slot_facts!(c::Compilation, ir::CC.IRCode, mi::Core.MethodInstance)
    generic_setproperty(mi) && return
    s = c.slots
    facts = Tuple{SlotKey,Any}[]
    s.facts_sink = facts
    s.fact_mi = mi
    try
        called = x -> CC.singleton_type(CC.argextype(x, ir))
        optype = x -> value_type_of(CC.argextype(x, ir))
        argof = x -> argument_index(ir, x)
        for pc in 1:length(ir.stmts)
            st = ir.stmts[pc][:stmt]
            if c.settings.why
                s.store_operand = nothing
                s.store_context = (mi, pc, st, nothing)
            end
            st isa Expr && learn_statement!(c, st, called, optype; argof, lattice = x -> CC.argextype(x, ir), pathof = x -> receiver_path(ir, x))
        end
        record_call_arguments!(facts, ir, mi)
        note_universe_statements!(c, (ir.stmts[pc][:type] for pc in 1:length(ir.stmts)), (ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts)), mi)
        note_slots_in_constants!(c, ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts))
    finally
        s.facts_sink = nothing
        s.fact_mi = nothing
    end
    result = s.current_result
    c.objects.pending_facts = nothing; c.objects.pending_mi = nothing
    if result isa CC.InferenceResult && result.overridden_by_const === nothing
        CC.stack_analysis_result!(result, SlotFactsResult(c.key, facts, mi in c.dispatch.used_in))
        c.objects.pending_facts = facts; c.objects.pending_mi = mi # (the facts of the objects are added to these after the code is inlined, see objects.jl)
    end
    return
end

## Types that reach a slot of types through the arguments of methods
#
# `push!(set, (MOI.VariableIndex, MOI.LessThan{Float64}))` stores the tuple in the keys of the `Dict` of the set in a method that is not inlined, which is given it as an argument of the type `Tuple{DataType,DataType}` (what the
# method is made for): what it stores is what its callers give it. So what is kept of a method is what it stores of its arguments (`(:argstore, (mi, n))`, the slot), which of its arguments it gives on to which argument
# of a call (`(:argpass, (callee, m))`, its own), and the types that are known that it gives to calls (`(:callarg, (callee, m))`, the type); and the stores are what the calls give, followed through the methods that give
# them on. A type that a caller gives that is not known (`DataType`) is not found: the read of the slot is checked, and the program stops if it has another type.

# the number of the argument of the method that `x` is (an argument, or what `convert`, a `typeassert` or a `π` makes of one: `key = convert(K, key0)` in `setindex!` of a `Dict`), or `nothing`
function argument_index(ir::CC.IRCode, @nospecialize(x))
    for _ in 1:8
        x isa Core.Argument && return x.n
        (x isa Core.SSAValue && x.id <= length(ir.stmts)) || return nothing
        st = ir.stmts[x.id][:stmt]
        if st isa Core.PiNode
            x = st.val
        elseif st isa Expr && st.head === :call && length(st.args) == 3
            f = CC.singleton_type(CC.argextype(st.args[1], ir))
            f === Base.convert ? (x = st.args[3]) : f === Core.typeassert ? (x = st.args[2]) : return nothing
        else
            return nothing
        end
    end
    return nothing
end

# whether an argument of this type can be a type or a tuple of types (the type of the specialization of a method: `DataType`, `Tuple{DataType,DataType}`)
can_hold_types(@nospecialize(P)) = P isa Type && P !== Union{} && (P <: Type || (P isa DataType && P <: Tuple && any(p -> p isa Type && can_hold_types(p), P.parameters)))

# the calls of a method (before it is inlined: a call and what inference found it to be), and what they give to the arguments of the methods that they call: see above
function record_call_arguments!(facts, ir::CC.IRCode, mi::Core.MethodInstance)
    c = compilation()
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr || continue
        callee = nothing
        first_arg = 0 # (the index in `st.args` of the argument 1 of the callee, its function)
        if st.head === :invoke
            target = st.args[1]
            callee = target isa Core.CodeInstance ? target.def : target
            first_arg = 2
        elseif st.head === :call
            # (the calls that give objects to methods are those of the code after it is inlined: see `record_object_facts!` in objects.jl)
            info = ir.stmts[pc][:info]
            info isa CC.MethodMatchInfo && length(info.results.matches) == 1 || continue
            callee = CC.specialize_method(only(info.results.matches))
            first_arg = 1
        end
        callee isa Core.MethodInstance || continue
        sig = Base.unwrap_unionall(callee.specTypes)
        sig isa DataType || continue
        nargs = length(st.args) - first_arg + 1
        nargs == length(sig.parameters) || continue
        for n in 2:nargs
            can_hold_types(sig.parameters[n]) || continue
            a = st.args[first_arg + n - 1]
            k = argument_index(ir, a)
            if k !== nothing
                push!(facts, ((:argpass, (callee, n), nothing), (mi, k)))
            else
                T = value_type_of(CC.argextype(a, ir))
                mentions_type_value(T) && push!(facts, ((:callarg, (callee, n), nothing), T))
            end
        end
    end
    return
end

# the stores of the types that calls give to arguments that are stored in a slot of types, through the methods that give them on
function resolve_argument_stores!(c::Compilation)
    s = c.slots
    isempty(s.argstores) && return
    stores = Dict{Any,Set{Any}}(k => copy(v) for (k, v) in s.argstores)
    changed = true
    while changed
        changed = false
        for (site, keys) in collect(stores), from in get(s.argpasses, site, ())
            target = get!(Set{Any}, stores, from)
            for key in keys
                key in target || (push!(target, key); changed = true)
            end
        end
    end
    for (site, keys) in stores, T in get(s.callargs, site, ()), key in keys
        note_slot_store!(c, key, T)
    end
    return
end

# What a code instance that was reached has kept (see `SlotFactsResult`): its facts are those of the program that reaches it
function replay_slot_facts!(c::Compilation, ci::Core.CodeInstance)
    s = c.slots
    r = slot_facts_of(ci)
    (r === nothing || r.key != c.key) && return
    for (key, T) in r.facts
        k = key[1]
        if k === :raw
            push!(s.raw_store_types, key[2])
        elseif k === :universe
            push!(s.universe_seen, key[2])
        elseif k === :truncated
            s.scan_truncated = true
        elseif k === :argstore
            push!(get!(Set{Any}, s.argstores, key[2]), T)
        elseif k === :argpass
            push!(get!(Set{Any}, s.argpasses, key[2]), T)
        elseif k === :callarg
            push!(get!(Vector{Any}, s.callargs, key[2]), T)
        elseif k === :objstore || k === :unattributed || k === :recvstore || k === :callsite || k === :invoked
            apply_object_fact!(c, k, key[2], key[3], T)
        elseif k === :written
            note_written!(c, key[2], key[3])
        else
            note_slot_store!(c, key, T)
        end
    end
    return
end

note_raw_store!(c::Compilation, @nospecialize(T)) = c.slots.facts_sink === nothing ? push!(c.slots.raw_store_types, T) : push!(c.slots.facts_sink, ((:raw, T, nothing), Any))

function CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState{<:OverridesInterpreter}, propagate_inbounds::Bool)
    mi = ir.debuginfo.def
    c = compilation()
    mi isa Core.MethodInstance && c.slots.mode !== :off && record_slot_facts!(c, ir, mi)
    # (without the slots, the constants are still looked at for their listeners, which are not known otherwise: see "Listeners" in closures.jl)
    c.slots.mode === :off && note_slots_in_constants!(c, (ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts)))
    inlined = @invoke CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState, propagate_inbounds::Bool)
    mi isa Core.MethodInstance && c.slots.mode !== :off && c.settings.objects && record_object_facts!(c, inlined, mi)
    return inlined
end

# What the constants that the code refers to hold in these slots: the elements of an array of `Any`, the fields of a struct that are of an abstract type, and the types of what is in them (for the universe). A constant is
# looked at with a list of what is to be looked at (not by calls of itself: what a program embeds can be a long chain, or deep, as a graph of objects is), each mutable object once (it can refer to itself), and as many objects
# as `SCAN_BUDGET` (a struct counts as one for each `SCAN_FIELDS` fields that it has). One that is larger is noted as such (`note_truncated!`): what it holds is not known, so the slots are not trusted (`analyze_slots!`), and the calls
# on what is read from them are made over the registered types. What is found in a constant is kept for the compilation (`SlotState.scan_cache`): the same constant is the operand of many statements.
const SCAN_BUDGET = 200_000
const SCAN_FIELDS = 64
note_truncated!(c::Compilation) = c.slots.facts_sink === nothing ? (c.slots.scan_truncated = true) : push!(c.slots.facts_sink, ((:truncated, nothing, nothing), Any))

scan_leaf(@nospecialize(x)) = x isa Type || x isa Module || x isa Symbol || x isa String || x isa Number || x isa Char

# the facts about the slots, and the universe, that are in `x0` and in what it refers to: `(slot, type of what is stored)`, `((:universe, type, nothing), Any)` and `((:truncated, nothing, nothing), Any)`, each once
# (whether objects of the type `T` hold listeners: asked once for each type in a compilation, and kept with it)
function holds_listeners(holders::IdDict{Any,Bool}, @nospecialize(T))
    h = get(holders, T, nothing)
    h === nothing || return h
    return holders[T] = Base.invokelatest(listener_holder, T)::Bool
end

function scan_facts(@nospecialize(x0), holders::IdDict{Any,Bool} = IdDict{Any,Bool}())
    facts = Set{Tuple{SlotKey,Any}}()
    seen = Base.IdSet{Any}()
    stack = Any[x0]
    budget = SCAN_BUDGET
    while !isempty(stack)
        x = pop!(stack)
        push!(facts, ((:universe, typeof(x), nothing), Any))
        scan_leaf(x) && continue
        # (an object that holds listeners, see "Listeners" in closures.jl: one that is mutable, as an `Observable` is, of a type that is said to hold them, which is asked once for each type in a compilation)
        if ismutable(x) && holds_listeners(holders, typeof(x))
            held = Base.invokelatest(held_listeners, x)
            if held !== nothing
                V, objects, types = held
                for f in objects; push!(facts, ((:listener, V, f), Any)); end
                for F in types; push!(facts, ((:listener_type, V, F), Any)); end
            end
        end
        if budget <= 0
            push!(facts, ((:truncated, nothing, nothing), Any))
            break
        end
        budget -= 1
        ismutable(x) && (x in seen ? continue : push!(seen, x))
        if x isa Core.GenericMemory
            key = (:elem, eltype(x), nothing)
            slot = needs_slot_type(eltype(x))
            (slot || !isbitstype(eltype(x))) || continue
            for i in eachindex(x)
                isassigned(x, i) || continue
                e = x[i]
                slot && push!(facts, (key, stored_value_type(e)))
                push!(stack, e)
            end
        elseif x isa Tuple
            for e in x
                push!(stack, e)
            end
        elseif isstructtype(typeof(x)) && !(x isa Core.CodeInstance) && !(x isa Core.MethodInstance) && !(x isa Method) && !(x isa Core.TypeName) &&
               !(x isa Task) # (a task is the state of the process that compiles: its scope, its storage, the tasks that wait for it. The tasks of a program are made by the program (see tasks.jl). `Base.roottask` is a constant of code that waits)
            S = typeof(x)
            budget -= fieldcount(S) ÷ SCAN_FIELDS # (a struct of many fields, Makie's `Axis` of 152, is looked at as an array of as many elements would be: its fields count as objects)
            for i in 1:fieldcount(S)
                isdefined(x, i) || continue
                v = getfield(x, i)
                needs_slot_type(fieldtype(S, i)) && push!(facts, ((:field, S, fieldname(S, i)), stored_value_type(v)))
                push!(stack, v)
            end
        end
    end
    return collect(facts)
end

function note_slots_in!(c::Compilation, @nospecialize(x))
    if scan_leaf(x)
        c.slots.mode === :off || note_universe!(c, typeof(x))
        return
    end
    # (not `get!` with a closure that has `x`: a closure of each type of constant is a method that Julia compiles)
    facts = get(c.slots.scan_cache, x, nothing)
    facts === nothing && (facts = c.slots.scan_cache[x] = scan_facts(x, c.closures.listener_holders))
    for (key, T) in facts
        k = key[1]
        if k === :listener
            note_listener!(c, key[2], key[3])
        elseif k === :listener_type
            (key[2], key[3]) in c.closures.seen_callbacks || push!(c.closures.seen_callbacks, (key[2], key[3]))
        elseif c.slots.mode === :off
            continue # (only the listeners are looked for: see `CC.ssa_inlining_pass!`)
        else
            k === :universe ? note_universe!(c, key[2]) : k === :truncated ? note_truncated!(c) : note_slot_store!(c, key, T)
        end
    end
    return
end

# The operands of a statement that can be constants: those of a call (the function too: a closure has what it captured), and what a `return`, a `φ` or a `π` has, which is where a function that is not inlined gives
# a container that is a constant (`f() = TABLE`); a statement that is only a constant (a global, a `QuoteNode`, an object) is its own operand.
function statement_operands(st)
    if st isa Expr
        st.head === :foreigncall && return ()
        skip = st.head === :call ? 1 : st.head === :invoke ? 2 : st.head === :new ? 2 : 1
        return (st.args[i] for i in skip:length(st.args))
    end
    st isa Core.ReturnNode && return isdefined(st, :val) ? (st.val,) : ()
    st isa Core.PiNode && return (st.val,)
    st isa Core.UpsilonNode && return isdefined(st, :val) ? (st.val,) : ()
    (st isa Core.PhiNode || st isa Core.PhiCNode) && return (st.values[i] for i in eachindex(st.values) if isassigned(st.values, i))
    st isa Union{Core.GotoNode,Core.GotoIfNot,Core.EnterNode,Core.SlotNumber,Core.NewvarNode,LineNumberNode,Core.SSAValue,Core.Argument,Nothing} && return ()
    return (st,)
end

# the value that a constant operand stands for, or `nothing`
function constant_operand(a)
    a isa GlobalRef && return isdefined(a.mod, a.name) && isconst(a.mod, a.name) ? getglobal(a.mod, a.name) : nothing
    a isa QuoteNode && return a.value
    a isa Core.BindingPartition && return is_const_partition(a) ? a.restriction : nothing # (optimized code refers to a global through its binding)
    return a isa Core.SSAValue || a isa Core.Argument || a isa Expr ? nothing : a
end

function note_slots_in_constants!(c::Compilation, code)
    for st in code
        for a in statement_operands(st)
            v = constant_operand(a)
            v === nothing && continue
            note_slots_in!(c, v)
        end
    end
    return
end

## the passes

# Run after inference (the types of all that is reached are in the cache, with the optimized code: what `juliac --trim` looks at, so that what is found is of what the program reaches, and does not depend on which methods were
# inferred in this pass and which were taken from the cache): the stores of the slots in the code that the program reaches, and what the reads of them are given in the next pass (`update_slot_types!`), until what is found is
# what was used
function analyze_slots!(c::Compilation, interp, root)
    s = c.slots
    s.mode === :off && return
    used = dispatch_was_used(c, interp, root)
    (isempty(s.types) && !used && s.mode !== :observe) && return
    # (what the roots that were made before in this pass stored is kept: a `@cfunction` is a root of its own, and the slots are those of the whole program)
    for (ci, src) in GPUCompiler.CompilerCaching.get_codeinfos(interp, root)
        src isa Core.CodeInfo && ci.def isa Core.MethodInstance || continue
        learn_slots!(c, src, ci.def)
        note_universe_statements!(c, src.ssavaluetypes isa Vector ? src.ssavaluetypes : Any[], src.code, ci.def)
        c.settings.why && (s.store_context = ("a constant that the code refers to", ci.def))
        note_slots_in_constants!(c, src.code)
    end
    for ci in reachable_code_instances(interp, root)
        c.settings.why && (s.store_context = ("kept from the inference of", ci.def))
        c.objects.replaying = ci.def
        try
            replay_slot_facts!(c, ci)
        finally
            c.objects.replaying = nothing
        end
    end
    resolve_object_stores!(c, root.def)
    c.settings.why && (s.store_context = "what the callers give to an argument that a method stores (see `resolve_argument_stores!`)")
    resolve_argument_stores!(c)
    if s.scan_truncated
        # If a constant is too large, the program is compiled as if there were no slots
        @debug "A constant exceeded the scan budget; slots disabled" _id = :static_slots_truncated
        trace_on() && trace("A constant exceeded the scan budget (more than ", SCAN_BUDGET, " objects); slots disabled")
        had_types = !isempty(s.types)
        empty!(s.types); s.type_slots = false
        s.mode = :off
        had_types && throw(SlotsChanged())
        return
    end
    if !isempty(s.raw_store_types)
        for k in union(collect(keys(s.seen)), collect(keys(s.types)))
            declared = k[1] === :elem ? k[2] : fieldtype(k[2], k[3])
            declared in s.raw_store_types && push!(s.seen_unknown, k)
        end
    end
    s.mode === :observe && return
    c.settings.why && report_why(c)
    changed = update_slot_types!(c)
    changed |= update_objects!(c) # (what is known of the objects, see objects.jl)
    # Program types, that a call over an `Any` splits over; any new finds that were not used in this pass are used in the next
    if c.settings.universe && used
        add_stored_types!(c)
        new = Any[t for t in s.universe_seen if !(t in s.universe)]
        # (the ones that are kept when there are too many are the first by name: which they are does not depend on the order that they were found in)
        length(s.universe) + length(new) > UNIVERSE_LIMIT && (new = sort!(new; by = string)[1:max(0, UNIVERSE_LIMIT - length(s.universe))])
        if !isempty(new)
            union!(s.universe, new)
            empty!(s.universe_extras)
            changed = true
        end
    end
    @debug "slots pass" pass = c.pass slot_passes = s.passes changed known = length(s.types) open = length(s.open) unknown = length(s.seen_unknown) universe = length(s.universe) _id = :static_slots
    changed || return
    s.passes += 1
    if s.passes > SLOT_PASS_LIMIT
        # (it does not settle: the compilation is made as if there were no slots)
        empty!(s.types); s.type_slots = false
        s.mode = :off
    end
    throw(SlotsChanged())
end

# (for `STATIC_RUNTIME_SLOTS_WHY`: where a store is, as text. It is kept as the method, the statement and its code, and made into text only for the stores that are reported: making it for each statement of a large program, as
# was done, took longer than compiling it)
function context_text(ctx)
    ctx isa Tuple || return string(ctx)
    length(ctx) == 2 && return string("(", ctx[1], ") ", ctx[2])
    mi, pc, st, src = ctx
    src === nothing && return string(mi, " #", pc, ": ", first(string(st), 120))
    code = src.code
    defs = [string("%", a.id, " = ", first(string(code[a.id]), 150), " :: ", src.ssavaluetypes[a.id]) for a in st.args if a isa Core.SSAValue]
    return string(mi, " #", pc, ": ", first(string(st), 160), "   WHERE ", join(defs, " ; "))
end

# (for `STATIC_RUNTIME_SLOTS_WHY`: why the slots are given up, as text on the error output)
function report_why(c::Compilation)
    s = c.slots
    if !isempty(s.unknown_census)
        by = Dict{SlotKey,Vector{Int}}() # (slot) => [stores of a type that is not known, of which a parameter of the method]
        example = Dict{SlotKey,String}()
        for (k, param, ctx) in s.unknown_census
            e = get!(by, k, [0, 0]); e[1] += 1; e[2] += param
            haskey(example, k) || (example[k] = ctx)
        end
        println(stderr, "== unknown stores found while looking at the code (all methods): ", length(s.unknown_census), ", of which the value is a parameter of the method: ", count(e -> e[2], s.unknown_census))
        for (k, e) in sort!(collect(by); by = p -> -p[2][1])[1:min(end, 12)]
            println(stderr, "   ", k[1], " ", k[2], " ", k[3], ": ", e[1], " stores, ", e[2], " of a parameter")
            println(stderr, "        e.g. ", first(example[k], 260))
        end
        for (k, param, ctx) in first(s.unknown_census, 6)
            println(stderr, "     e.g. ", param ? "[parameter] " : "", first(ctx, 200))
        end
    end
    println(stderr, "== slots, pass ", s.passes, ": ", length(s.types), " known, ", length(s.open), " open; unknown stores in ", length(s.seen_unknown), " slots")
    for (k, T) in s.seen
        println(stderr, "   seen ", k[1], " ", k[2], " ", k[3], " => ", T)
    end
    for k in s.seen_unknown
        println(stderr, "   ", k[1], " ", k[2], " ", k[3], k in s.open ? "  (open already)" : haskey(s.types, k) ? "  (known: $(Base.unionlen(s.types[k])) types)" : "  (not known yet)")
        for w in get(s.unknown_stores, k, String[])
            println(stderr, "        ", first(w, 300))
        end
    end
    return
end

function GPUCompiler.drive_inference!(interp::OverridesInterpreter, mi::Core.MethodInstance)
    root = @invoke GPUCompiler.drive_inference!(interp::CC.AbstractInterpreter, mi::Core.MethodInstance)
    if root isa Core.CodeInstance
        replay_findings!(compilation(), interp, root) # (what inference found of the methods that were taken from the cache: see `InferenceFindings`)
        analyze_slots!(compilation(), interp, root)
    end
    return root
end

# The types that the reads of the slots are given next, from what was stored in them in the pass that was made: the first time, the types that are known of what was stored (what is stored that is read from a slot
# is of a type that is not known in that pass, as an `Any`, and is not counted); after that, what was stored with the reads as they were given has to be of those types: if it is, they are the ones; if it is of other types, those
# are added; if something that is of a type that is not known is stored, the slot is given up. Returns whether any changed.
function update_slot_types!(c::Compilation)
    s = c.slots
    changed = false
    for (k, T) in s.seen
        k in s.open && continue
        used = get(s.types, k, nothing)
        if used === nothing
            T === Union{} && continue
            s.types[k] = T
            changed = true
        elseif k in s.seen_unknown
            delete!(s.types, k)
            push!(s.open, k)
            changed = true
        elseif T === Union{} || T === used
            continue
        elseif T <: used
            @debug "slot narrowed" key = k from = used to = T _id = :static_slot_changes
            s.types[k] = T
            changed = true
        else
            new = Union{used, T}
            @debug "slot widened" key = k from = used added = T _id = :static_slot_changes
            if Base.unionlen(new) > c.settings.slot_limit
                delete!(s.types, k)
                push!(s.open, k)
            else
                s.types[k] = new
            end
            changed = true
        end
    end
    s.type_slots = any(k -> get!(() -> type_value_declared(k[1] === :elem ? k[2] : fieldtype(k[2], k[3])), s.holds_types, k), keys(s.types))
    empty!(s.type_values)
    if s.type_slots
        for (k, U) in s.types
            get(s.holds_types, k, false) && collect_type_values!(s.type_values, U)
        end
        unique!(s.type_values)
    end
    return changed
end

# The type of a read from a slot of the types that were stored in it, as precise as what inference had for it before (`rt`): the part of it that is of the types that the declared type has
function refined_read(@nospecialize(T), @nospecialize(rt))
    R = typeintersect(T, CC.widenconst(rt))
    return R === Union{} ? rt : R
end

# the type that a read of a slot is given, or `nothing`
function slot_read_type(c::Compilation, key)
    assumed = get(c.registered.fields, key, nothing) # (a type that is stated: see assume.jl)
    assumed === nothing || return assumed
    return c.slots.mode === :on ? get(c.slots.types, key, nothing) : nothing
end

# What was found, as lines to read: the slot, and the types (or that they are not known). Of the last compilation, unless one is given.
function slots_report(io::IO = stdout, c::Union{Nothing,Compilation} = LAST_COMPILATION[])
    c === nothing && return
    for (key, T) in sort!(collect(c.slots.seen); by = p -> string(p[1]))
        what = key[1] === :elem ? string("elements of Memory{", key[2], "}") : string(key[2], ".", key[3])
        println(io, rpad(what, 60), T === Any ? "NOT KNOWN" : string(Base.unionlen(T), " types: ", T))
    end
end
