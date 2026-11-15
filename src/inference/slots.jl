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
const SLOT_PASS_LIMIT = 4
# Every read of a slot that was given the types that were stored in it is checked (`check_slot_reads!`, dispatch.jl): the program stops if the value is of another type, as it would be if a store were missed. It is on when the compilation is `strict` (the default), and `STATIC_RUNTIME_CHECK_TYPES=0` turns it off (`1` turns it on for `strict = false`); it costs nothing that could be measured in the benchmarks of `bench/dispatch.jl` (see `Settings`)
const SLOT_LIMIT = Ref(64) # the most types that a slot holds before it is given up
# the number of the types of the universe that a compilation adds (the types of a program that is compiled: more are not added, so that what is found settles)
const UNIVERSE_LIMIT = 512

# Whether this compilation has called anything over the registered types (a value of the type `Any` that it dispatched on): when it has not, there is nothing that the types of the slots would change.
# What was inferred before is taken from the cache, where this is not seen again: so the keys of the inference cache that it was true for are kept (they are made of all that inference depends on, so what is true of one is true of
# every compilation that has it)
const DISPATCH_USED_KEYS = Set{Int}()
function note_dispatch_used!(c::Compilation)
    c.dispatch.registered_used = true
    push!(DISPATCH_USED_KEYS, c.key)
    return
end
dispatch_was_used(c::Compilation) = c.dispatch.registered_used || c.key in DISPATCH_USED_KEYS

## The universe: the types that the program makes
#
# A call with an argument of the type `Any` is made over the types that were registered (dispatch.jl), and a value of another type that reaches it aborts the program. The values of a program are made in its code, which is what is
# compiled: a type that nothing makes is not one that a value can have. The types of the statements of the code that is reached (and of the constants that it refers to) are those that the program can make, and the ones that are not
# types of Julia itself (those that are not defined in `Core`, `Base`, the standard library or this package, or that have one of them as a parameter: `Vector{MyType}`) are added to the types that a call with an `Any` is made over, where a method fits them. The types that are
# found in a pass are the ones that are used in the next, until a pass finds no more (the types make code reached that makes others); a program that makes no such types needs no more passes than it did. `STATIC_RUNTIME_UNIVERSE=0` leaves them out.
# (The registered types that the program does not make are not left out, which was tried: the types that a first pass finds are those of a call over all the registered types, and each of those makes values of its own type, so nothing is
# left out, and the extra pass costs half of the time of compiling. A program that gets an object of a type that it does not make has a `MethodError` that says so.)

# whether a module is one of Julia's own (the standard library, Base and Core, and this package), whose types are the ones that are registered when a program is likely to have them
# (what a module is does not change: it is kept)
const JULIA_OWNED_MODULES = Dict{Module,Bool}()
function julia_owned_module(m::Module)
    get!(JULIA_OWNED_MODULES, m) do
        root = Base.moduleroot(m)
        (root === Core || root === Base || root === StaticRuntime || root === StaticTools) && return true # (the package, and what its programs are made with)
        path = pathof(root)
        return path !== nothing && startswith(path, Sys.STDLIB)
    end
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
    get!(s.universe_extras, T) do
        Any[t for t in s.universe if t <: T]
    end
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
needs_slot_type(@nospecialize(T)) = !(isconcretetype(T) || (T isa Union && all(isconcretetype, Base.uniontypes(T))) || T <: Type)

# whether a type is one that a slot can be said to hold: concrete, or a union of them
closed_type(@nospecialize(T)) = all(isconcretetype, Base.uniontypes(T))

# The type of what is stored where the type of the value is `T`: a value of a type that is `Type{...}`, or `Type`, is a type object, which is a `DataType`, a `UnionAll` or a `Union` (a type that is not concrete otherwise)
function stored_type(@nospecialize(T))
    T isa Union && return Union{(stored_type(t) for t in Base.uniontypes(T))...}
    return !isconcretetype(T) && T <: Type ? Union{DataType,UnionAll,Union} : T
end

function note_slot_store!(c::Compilation, key::SlotKey, @nospecialize(T))
    s, settings = c.slots, c.settings
    T = stored_type(T)
    T === Union{} && return
    key in c.registered.embedded && !closed_type(T) && return # (see `@assume_field_embedded`: the reads are checked)
    if s.facts_sink !== nothing
        settings.why && !closed_type(T) && push!(s.unknown_census, (key, s.store_operand isa Core.Argument, string(s.store_context)))
        push!(s.facts_sink, (key, T))
        return
    end
    isempty(settings.blind) || (T = Union{(t for t in Base.uniontypes(T) if !(string(t) in settings.blind))...}; T === Union{} && return)
    cur = get!(s.seen, key, Union{})
    if !closed_type(T)
        push!(s.seen_unknown, key)
        if settings.why
            why = get!(Vector{String}, s.unknown_stores, key)
            length(why) < 6 && push!(why, string(T, "  in  ", s.store_context))
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
    any(R -> T <: R, REFLECTION_TYPES) && return
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

# the type of an operand of a statement of optimized code, where the arguments are those of the specialization of the method
function slot_operand_type(src::Core.CodeInfo, mi::Core.MethodInstance, x)
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
function learn_statement!(c::Compilation, call::Expr, called, optype)
    s = c.slots
    store!(key, operand) = (s.store_operand = operand; note_slot_store!(c, key, optype(operand)))
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
            operand = f === Core.modifyfield! || length(call.args) < i ? nothing : call.args[i]
            T = operand === nothing ? Any : optype(operand)
            if name === nothing
                # (a field that is not known when compiling: any of the fields that hold an unknown type may be it)
                S isa DataType && isconcretetype(S) && isstructtype(S) &&
                    for i in 1:fieldcount(S); needs_slot_type(fieldtype(S, i)) && note_slot_store!(c, (:field, S, fieldname(S, i)), Any); end
            else
                key = field_slot_key(S, name)
                key === nothing || (s.store_operand = operand; note_slot_store!(c, key, T))
            end
        elseif f isa Core.IntrinsicFunction && nameof(f) in (:pointerset, :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace)
            # (a store through a pointer to values of an abstract type: into any memory that holds them, and any field of that type)
            P = CC.widenconst(optype(call.args[2]))
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
function learn_slots!(c::Compilation, src::Core.CodeInfo, mi::Core.MethodInstance)
    s = c.slots
    code = src.code
    called = x -> called_function(code, x)
    optype = x -> slot_operand_type(src, mi, x)
    for pc in eachindex(code)
        st = code[pc]
        call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
        call isa Expr || continue
        if c.settings.why
            defs = [string("%", a.id, " = ", first(string(code[a.id]), 150), " :: ", src.ssavaluetypes[a.id]) for a in call.args if a isa Core.SSAValue]
            s.store_context = string(mi, " #", pc, ": ", first(string(call), 160), "   WHERE ", join(defs, " ; "))
        end
        learn_statement!(c, call, called, optype)
    end
    return
end

# The stores of a method as they are before the inliner and the scalar replacement have been at it (a `Pair` that only holds the value that is read from a `Dict` for a moment is not there afterwards, and the type of its field is
# read all the same), as facts about the method that are kept, so that the method is not looked at again when it is taken from the cache: (the method, the key of the cache) => the stores as (slot, type)
# (it is a cache of what is true of a method for a key of the inference cache, which is made of all that inference depends on: it is kept for as long as what is inferred is, which is longer than a compilation)
# (An `IdDict` by the method, and the key inside it: the key of a table that is looked in is a number made of the address of the method, which is not the same when the image of a package that has the table is loaded. Julia makes
# an `IdDict` again when it loads one, but not every entry of it is found by what is looked for afterwards, so `rehash_slot_facts!` makes it again when this package is loaded. The workload of `precompile.jl` has filled it in, and
# what is found of the programs of it is found with it.)
const SLOT_FACTS = IdDict{Core.MethodInstance,Dict{Int,Vector{Tuple{SlotKey,Any}}}}()

function record_slot_facts!(c::Compilation, ir::CC.IRCode, mi::Core.MethodInstance)
    s = c.slots
    facts = Tuple{SlotKey,Any}[]
    s.facts_sink = facts
    try
        called = x -> CC.singleton_type(CC.argextype(x, ir))
        optype = x -> CC.widenconst(CC.argextype(x, ir))
        for pc in 1:length(ir.stmts)
            st = ir.stmts[pc][:stmt]
            if c.settings.why
                s.store_operand = nothing
                s.store_context = string(mi, " #", pc, ": ", first(string(st), 120))
            end
            st isa Expr && learn_statement!(c, st, called, optype)
        end
        note_universe_statements!(c, (ir.stmts[pc][:type] for pc in 1:length(ir.stmts)), (ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts)), mi)
        note_slots_in_constants!(c, ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts))
    finally
        s.facts_sink = nothing
    end
    get!(Dict{Int,Vector{Tuple{SlotKey,Any}}}, SLOT_FACTS, mi)[c.key] = facts
    return
end

# the table of the facts made again, as it has to be when it was loaded from the image of the package (the entries are all there, by iterating, and not all of them are found by their keys)
function rehash_slot_facts!()
    entries = collect(SLOT_FACTS)
    empty!(SLOT_FACTS)
    for (mi, bykey) in entries
        SLOT_FACTS[mi] = bykey
    end
    return nothing
end

# The facts of every method that the code that was compiled depends on, which the inlined ones are among (the edges of a method are the methods that it calls and those that were inlined into it)
function replay_reachable_facts!(c::Compilation, root::Core.CodeInstance)
    seen = Base.IdSet{Any}()
    stack = Any[root]
    while !isempty(stack)
        ci = pop!(stack)
        ci in seen && continue
        push!(seen, ci)
        ci isa Core.CodeInstance || continue
        ci.def isa Core.MethodInstance && replay_slot_facts!(c, ci.def)
        for e in ci.edges
            e isa Core.CodeInstance && push!(stack, e)
            e isa Core.MethodInstance && replay_slot_facts!(c, e)
        end
    end
    return
end

function replay_slot_facts!(c::Compilation, mi::Core.MethodInstance)
    s = c.slots
    bykey = get(SLOT_FACTS, mi, nothing)
    bykey === nothing && return
    facts = get(bykey, c.key, nothing)
    facts === nothing && return
    for (key, T) in facts
        key[1] === :raw ? push!(s.raw_store_types, key[2]) : key[1] === :universe ? push!(s.universe_seen, key[2]) : key[1] === :truncated ? (s.scan_truncated = true) : note_slot_store!(c, key, T)
    end
    return
end

note_raw_store!(c::Compilation, @nospecialize(T)) = c.slots.facts_sink === nothing ? push!(c.slots.raw_store_types, T) : push!(c.slots.facts_sink, ((:raw, T, nothing), Any))

function CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState{<:OverridesInterpreter}, propagate_inbounds::Bool)
    mi = ir.debuginfo.def
    c = compilation()
    mi isa Core.MethodInstance && c.slots.mode !== :off && record_slot_facts!(c, ir, mi)
    return @invoke CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState, propagate_inbounds::Bool)
end

# What the constants that the code refers to hold in these slots: the elements of an array of `Any`, the fields of a struct that are of an abstract type, and the types of what is in them (for the universe). A constant is
# looked at with a list of what is to be looked at (not by calls of itself: what a program embeds can be a long chain, or deep, as a graph of objects is), each mutable object once (it can refer to itself), and as many objects
# as `SCAN_BUDGET`. One that is larger, or a struct that has more than `SCAN_FIELDS` fields, is noted as such (`note_truncated!`): what it holds is not known, so the slots are not trusted (`analyze_slots!`), and the calls
# on what is read from them are made over the registered types. What is found in a constant is kept for the compilation (`SlotState.scan_cache`): the same constant is the operand of many statements.
const SCAN_BUDGET = 200_000
const SCAN_FIELDS = 64
note_truncated!(c::Compilation) = c.slots.facts_sink === nothing ? (c.slots.scan_truncated = true) : push!(c.slots.facts_sink, ((:truncated, nothing, nothing), Any))

scan_leaf(@nospecialize(x)) = x isa Type || x isa Module || x isa Symbol || x isa String || x isa Number || x isa Char

# the facts about the slots, and the universe, that are in `x0` and in what it refers to: `(slot, type of what is stored)`, `((:universe, type, nothing), Any)` and `((:truncated, nothing, nothing), Any)`, each once
function scan_facts(@nospecialize(x0))
    facts = Set{Tuple{SlotKey,Any}}()
    seen = Base.IdSet{Any}()
    stack = Any[x0]
    budget = SCAN_BUDGET
    while !isempty(stack)
        x = pop!(stack)
        push!(facts, ((:universe, typeof(x), nothing), Any))
        scan_leaf(x) && continue
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
                slot && push!(facts, (key, typeof(e)))
                push!(stack, e)
            end
        elseif x isa Tuple
            for e in x
                push!(stack, e)
            end
        elseif isstructtype(typeof(x)) && !(x isa Core.CodeInstance) && !(x isa Core.MethodInstance) && !(x isa Method) && !(x isa Core.TypeName) &&
               !(x isa Task) # (a task is the state of the process that compiles: its scope, its storage, the tasks that wait for it. The tasks of a program are made by the program (see tasks.jl). `Base.roottask` is a constant of code that waits)
            S = typeof(x)
            if fieldcount(S) > SCAN_FIELDS
                push!(facts, ((:truncated, nothing, nothing), Any))
                continue
            end
            for i in 1:fieldcount(S)
                isdefined(x, i) || continue
                v = getfield(x, i)
                needs_slot_type(fieldtype(S, i)) && push!(facts, ((:field, S, fieldname(S, i)), typeof(v)))
                push!(stack, v)
            end
        end
    end
    return collect(facts)
end

function note_slots_in!(c::Compilation, @nospecialize(x))
    if scan_leaf(x)
        note_universe!(c, typeof(x))
        return
    end
    facts = get!(() -> scan_facts(x), c.slots.scan_cache, x)
    for (key, T) in facts
        k = key[1]
        k === :universe ? note_universe!(c, key[2]) : k === :truncated ? note_truncated!(c) : note_slot_store!(c, key, T)
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
    (isempty(s.types) && !dispatch_was_used(c) && s.mode !== :observe) && return
    # (what the roots that were made before in this pass stored is kept: a `@cfunction` is a root of its own, and the slots are those of the whole program)
    for (ci, src) in GPUCompiler.CompilerCaching.get_codeinfos(interp, root)
        src isa Core.CodeInfo && ci.def isa Core.MethodInstance || continue
        learn_slots!(c, src, ci.def)
        note_universe_statements!(c, src.ssavaluetypes isa Vector ? src.ssavaluetypes : Any[], src.code, ci.def)
        note_slots_in_constants!(c, src.code)
    end
    replay_reachable_facts!(c, root)
    if s.scan_truncated
        # (a constant is too large to be looked at all of: what the slots hold is not known, and the program is compiled as if there were no slots)
        @debug "A constant that the program refers to is too large to find what it holds: slots are not used" _id = :static_slots_truncated
        had_types = !isempty(s.types)
        empty!(s.types)
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
    # (the types that the program makes, that a call over an `Any` is made over: the ones found that were not used in this pass are used in the next)
    if c.settings.universe && dispatch_was_used(c)
        add_stored_types!(c)
        new = Any[t for t in s.universe_seen if !(t in s.universe)]
        length(s.universe) + length(new) > UNIVERSE_LIMIT && (new = new[1:max(0, UNIVERSE_LIMIT - length(s.universe))])
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
        empty!(s.types)
        s.mode = :off
    end
    throw(SlotsChanged())
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
    root isa Core.CodeInstance && analyze_slots!(compilation(), interp, root)
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
