# Slots that hold values of an abstract type: what is stored in them.
#
# The elements of a `Vector{Any}`, and the fields of a struct that are of the type `Any` or an abstract type, hold values of types that inference does not know, so what is read from them is an `Any`, and a call
# on it is made over the *registered* types (see dispatch.jl): a value of another type aborts the program. The types that the slot holds are the types of what the program stores in it, all of which are in the code that
# is compiled (and in the constants that it refers to): `Any[1, "a", (2, 3.5)]` holds an `Int`, a `String` and a `Tuple{Int,Float64}`. This finds them, and says what it found (it does not change what is compiled yet).
#
# A slot is the elements of one type of memory (`Memory{Any}`: all the `Vector{Any}` and the `Dict{K,Any}` of the program are one), or the field of a struct (`RefValue{Any}.x`, a field of the type `Any` of a struct of
# the program). The key of a slot is `(:elem, T, nothing)` or `(:field, S, name)`.

const SlotKey = Tuple{Symbol,Any,Any}

# the types that the slots held in the compilation that is made now: the union of the types of what was stored, or `Any` when something of a type that is not known was (so that what the slot holds is not known)
const SEEN_SLOTS = Dict{SlotKey,Any}()
const SLOT_LIMIT = Ref(64)
# `:on` (the types are used), `:observe` (found and kept in `SEEN_SLOTS`, and not used), `:off`: `STATIC_RUNTIME_SLOTS` is `1`/unset, `observe` or `0`
const SLOTS_MODE = Ref(:on)

# The types that reads of each slot are given in this compilation (see `update_slot_types!`), the slots that are given up (what is stored in them is not known: a read of one is an `Any`, over the registered types), and the
# slots that something of a type that is not known was stored in, in the pass that was made last
const SLOT_TYPES = Dict{SlotKey,Any}()
const SLOT_OPEN = Set{SlotKey}()
const SEEN_UNKNOWN = Set{SlotKey}()
const SLOT_PASSES = Ref(0)
# whether a compilation that failed with the types of the slots was made again without them (once)
const SLOTS_FALLBACK = Ref(false)
const SLOT_PASS_LIMIT = 4
# (for finding out why a slot is given up: the first stores of a type that is not known, as text; kept when `STATIC_RUNTIME_SLOTS_WHY` is set)
const SLOTS_WHY = Ref(false)
# Every read of a slot that was given the types that were stored in it is checked (`check_slot_reads!`, dispatch.jl): the program stops if the value is of another type, as it would be if a store were missed. It is on when the compilation is `strict` (the default), and `STATIC_RUNTIME_CHECK_TYPES=0` turns it off (`1` turns it on for `strict = false`); it costs nothing that could be measured in the benchmarks of `bench/dispatch.jl`
const UNKNOWN_STORES = Dict{SlotKey,Vector{String}}()
const STORE_CONTEXT = Ref{Any}(nothing)
# (for `STATIC_RUNTIME_SLOTS_WHY`: the operand of the store that is being noted, and the stores of a type that is not known that were found while the code was looked at: (slot, what is stored is a parameter of the method, where))
const STORE_OPERAND = Ref{Any}(nothing)
const UNKNOWN_CENSUS = Tuple{SlotKey,Bool,String}[]
const CHECK_SLOT_TYPES = Ref(false)
# (for testing the check: `STATIC_RUNTIME_SLOTS_BLIND=String,Int` makes the analysis miss the stores of these types, as it would a store that it can not see)
const BLIND_TYPES = Set{String}()
# the declared types of the slots that a store through a pointer was seen to write (a pointer can point into the elements of a memory and into a field): the slots of them are not known
const RAW_STORE_TYPES = Set{Any}()

# Whether this compilation has called anything over the registered types (a value of the type `Any` that it dispatched on): when it has not, there is nothing that the types of the slots would change
const REGISTERED_DISPATCH_USED = Ref(false)
# The keys of the inference cache (`OverridesParams`) that this was true for: what is inferred before is taken from the cache, where this is not seen again
const DISPATCH_PARAMS = Set{Int}()
function note_dispatch_used!()
    REGISTERED_DISPATCH_USED[] = true
    push!(DISPATCH_PARAMS, OverridesParams().candidates)
    return
end
dispatch_was_used() = REGISTERED_DISPATCH_USED[] || OverridesParams().candidates in DISPATCH_PARAMS

## The universe: the types that the program makes
#
# A call with an argument of the type `Any` is made over the types that were registered (dispatch.jl), and a value of another type that reaches it aborts the program. The values of a program are made in its code, which is what is
# compiled: a type that nothing makes is not one that a value can have. The types of the statements of the code that is reached (and of the constants that it refers to) are those that the program can make, and the ones that are not
# types of Julia itself (those that are not defined in `Core`, `Base`, the standard library or this package, or that have one of them as a parameter: `Vector{MyType}`) are added to the types that a call with an `Any` is made over, where a method fits them. The types that are
# found in a pass are the ones that are used in the next, until a pass finds no more (the types make code reached that makes others); a program that makes no such types needs no more passes than it did. `STATIC_RUNTIME_UNIVERSE=0` leaves them out.
# (The registered types that the program does not make are not left out, which was tried: the types that a first pass finds are those of a call over all the registered types, and each of those makes values of its own type, so nothing is
# left out, and the extra pass costs half of the time of compiling. A program that gets an object of a type that it does not make has a `MethodError` that says so.)
const UNIVERSE_MODE = Ref(:add)
const UNIVERSE_SEEN = Set{Any}()
const UNIVERSE_USED = Set{Any}()
const UNIVERSE_VERSION = Ref(0)
const UNIVERSE_LIMIT = 512 # (the types of a program that is compiled: more are not added, so that what is found settles)
const UNIVERSE_EXTRAS = Dict{Any,Vector{Any}}()
const STORED_BY_SLOT = Dict{SlotKey,Set{Any}}() # (the types that were stored in each slot of an abstract type, in this pass: those of the slots that are open are in the universe, see `note_stored_type!`)

# whether a module is one of Julia's own (the standard library, Base and Core, and this package), whose types are the ones that are registered when a program is likely to have them
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

function note_universe!(@nospecialize(T))
    UNIVERSE_MODE[] === :off && return
    T = CC.widenconst(T)
    user_relevant(T) || return
    FACTS_SINK[] === nothing ? push!(UNIVERSE_SEEN, T) : push!(FACTS_SINK[], ((:universe, T, nothing), Any))
    return
end

# the types of the universe that are subtypes of `T` (for the types that a call is made over)
function universe_extras(@nospecialize(T))
    (UNIVERSE_MODE[] !== :off && !isempty(UNIVERSE_USED)) || return Any[]
    get!(UNIVERSE_EXTRAS, (T, UNIVERSE_VERSION[])) do
        Any[t for t in UNIVERSE_USED if t <: T]
    end
end

# a hash of the types that the universe has, for the key of the inference cache (as for `slots_hash`)
function universe_hash()
    h = UInt(0)
    for t in UNIVERSE_USED
        h += UInt(objectid(t))
    end
    return hash(length(UNIVERSE_USED), h)
end

# the types that the statements of a method have (those of the optimized code of it, or of the code before it was optimized), and its arguments
function note_universe_statements!(types, stmts, mi::Core.MethodInstance)
    UNIVERSE_MODE[] === :off && return
    sig = Base.unwrap_unionall(mi.specTypes)
    sig isa DataType && for T in sig.parameters
        T isa Type && note_universe!(T)
    end
    for (st, T) in zip(stmts, types)
        # (a `PiNode` and a `PhiNode` have the type of values that are made elsewhere, and what a `typeassert` gives is the type of its argument: a type that is only there because a call was made over it is not one that is made)
        (st isa Core.PiNode || st isa Core.PhiNode || st isa Core.PhiCNode || st isa Core.UpsilonNode) && continue
        T isa Type || T isa Core.Const || T isa Core.PartialStruct || continue
        note_universe!(T)
    end
    return
end

# said when the types of the slots have changed, so that the compilation is made again with them (the pass is cut short: inference is what they are found from)
struct SlotsChanged <: Exception end

# A hash of the types of the slots, for the key of the inference cache. (`hash` of a `Union` does not tell unions apart, so this is made of the objectids of the types in them. The order does not matter.)
function slots_hash()
    h = UInt(0)
    for (k, T) in SLOT_TYPES
        members = sort!(UInt[objectid(t) for t in Base.uniontypes(T)])
        h += hash(members, hash(objectid(k[2]), hash(k[1], hash(k[3]))))
    end
    return hash(length(SLOT_TYPES), h)
end

# at the start of each pass of the compilation
function reset_slots_pass!()
    PASS_PARAMS_KEY[] = OverridesParams().candidates
    empty!(UNIVERSE_SEEN)
    empty!(STORED_BY_SLOT)
    empty!(RAW_STORE_TYPES)
    SCAN_TRUNCATED[] = false
    empty!(SEEN_SLOTS)
    empty!(SEEN_UNKNOWN)
    empty!(UNKNOWN_STORES)
    return
end

function reset_slots!(; strict::Bool = true)
    empty!(SLOT_TYPES)
    empty!(SLOT_OPEN)
    empty!(SEEN_SLOTS)
    empty!(SEEN_UNKNOWN)
    SLOT_PASSES[] = 0
    empty!(SCAN_CACHE)
    SLOTS_FALLBACK[] = get(ENV, "STATIC_RUNTIME_SLOTS_FALLBACK", "1") == "0" # (`0`: a compilation that fails with the types of the slots is not made again without them, for finding out what failed)
    SCAN_TRUNCATED[] = false
    mode = get(ENV, "STATIC_RUNTIME_SLOTS", "on")
    SLOTS_MODE[] = mode == "0" ? :off : mode == "observe" ? :observe : :on
    PRECISE_NOSPECIALIZEINFER[] = get(ENV, "STATIC_RUNTIME_NOSPECIALIZEINFER", "1") != "0"
    FILTER_BY_METHODS[] = get(ENV, "STATIC_RUNTIME_METHOD_FILTER", "1") != "0"
    UNIVERSE_MODE[] = get(ENV, "STATIC_RUNTIME_UNIVERSE", "1") == "0" ? :off : :add
    empty!(UNIVERSE_USED)
    empty!(UNIVERSE_SEEN)
    empty!(UNIVERSE_EXTRAS)
    empty!(REGISTERED_UNIONS)
    UNIVERSE_VERSION[] += 1
    SLOTS_WHY[] = haskey(ENV, "STATIC_RUNTIME_SLOTS_WHY")
    # (the check is on when the compilation is `strict`, and `STATIC_RUNTIME_CHECK_TYPES` is `1` (on) or `0` (off) for either)
    check = get(ENV, "STATIC_RUNTIME_CHECK_TYPES", "")
    CHECK_SLOT_TYPES[] = isempty(check) ? strict : check != "0"
    empty!(BLIND_TYPES)
    union!(BLIND_TYPES, filter(!isempty, split(get(ENV, "STATIC_RUNTIME_SLOTS_BLIND", ""), ',')))
    empty!(UNKNOWN_STORES)
    return
end

# whether what is read from a slot of the declared type `T` has a type that is not known: `Any`, an abstract type, a union with one of them. (A concrete type, and a union of them, are known already.)
needs_slot_type(@nospecialize(T)) = !(isconcretetype(T) || (T isa Union && all(isconcretetype, Base.uniontypes(T))) || T <: Type)

# whether a type is one that a slot can be said to hold: concrete, or a union of them
closed_type(@nospecialize(T)) = all(isconcretetype, Base.uniontypes(T))

# The type of what is stored where the type of the value is `T`: a value of a type that is `Type{...}`, or `Type`, is a type object, which is a `DataType`, a `UnionAll` or a `Union` (a type that is not concrete otherwise)
function stored_type(@nospecialize(T))
    T isa Union && return Union{(stored_type(t) for t in Base.uniontypes(T))...}
    return !isconcretetype(T) && T <: Type ? Union{DataType,UnionAll,Union} : T
end

function note_slot_store!(key::SlotKey, @nospecialize(T))
    T = stored_type(T)
    T === Union{} && return
    !isempty(EMBEDDED_SLOTS) && key in EMBEDDED_SLOTS && !closed_type(T) && return # (see `@assume_field_embedded`: the reads are checked)
    if FACTS_SINK[] !== nothing
        SLOTS_WHY[] && !closed_type(T) && push!(UNKNOWN_CENSUS, (key, STORE_OPERAND[] isa Core.Argument, string(STORE_CONTEXT[])))
        push!(FACTS_SINK[], (key, T))
        return
    end
    isempty(BLIND_TYPES) || (T = Union{(t for t in Base.uniontypes(T) if !(string(t) in BLIND_TYPES))...}; T === Union{} && return)
    cur = get!(SEEN_SLOTS, key, Union{})
    if !closed_type(T)
        push!(SEEN_UNKNOWN, key)
        if SLOTS_WHY[]
            why = get!(Vector{String}, UNKNOWN_STORES, key)
            length(why) < 6 && push!(why, string(T, "  in  ", STORE_CONTEXT[]))
        end
        return
    end
    new = Union{cur, T}
    Base.unionlen(new) > SLOT_LIMIT[] ? push!(SEEN_UNKNOWN, key) : (SEEN_SLOTS[key] = new)
    for t in Base.uniontypes(T)
        note_stored_type!(key, t)
    end
    return
end

# A type that the program stores in a slot of an abstract type is one that a value of that type can have, whoever defines it (a `Vector{Int}` or a `Tuple{Int,Float64}` in a `Vector{Any}`: the types that are made by the
# program that are not user types are not in the universe otherwise, and are not registered), so a call on a value of the type `Any` is made over it too, where the slot is one that is not known (see `note_universe!`).
# Only for a slot that is open at the end of the pass (`add_stored_types!`): a slot that has types has those for what is read from it, and the types that all the slots of a program store, as the types that a call is made over,
# are many (the program that is made of `String`s and `Symbol`s of a `Vector{Any}` has hundreds), which a call over a value that is not known is split by.
# (the types of the type system, that the code of Base keeps in a `Vector{Any}` while it works with types (`typejoin`), are not values of a program: a call that is made over them is one that is not wanted)
const REFLECTION_TYPES = Any[TypeVar, Core.TypeofVararg, Core.TypeName, Module, Method, Core.MethodInstance, Core.CodeInstance, Core.SimpleVector]
function note_stored_type!(key::SlotKey, @nospecialize(T))
    UNIVERSE_MODE[] === :off && return
    (T isa DataType && isconcretetype(T) && !(T <: Function) && !(T <: Type)) || return
    any(R -> T <: R, REFLECTION_TYPES) && return
    (T in DEFAULT_DISPATCH_CANDIDATES || T in SHOW_CANDIDATES) && return # (registered already)
    push!(get!(Set{Any}, STORED_BY_SLOT, key), T)
    return
end

# the types that were stored in the slots that are open, as types of the universe
function add_stored_types!()
    for (key, types) in STORED_BY_SLOT
        (key in SLOT_OPEN || key in SEEN_UNKNOWN) || continue
        union!(UNIVERSE_SEEN, types)
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
function learn_statement!(call::Expr, called, optype)
    store!(key, operand) = (STORE_OPERAND[] = operand; note_slot_store!(key, optype(operand)))
    if call.head === :call && length(call.args) >= 3
        f = called(call.args[1])
        if f === Core.memoryrefset!
            key = elem_slot_key(optype(call.args[2]))
            key === nothing || store!(key, call.args[3])
        elseif f === Core.memoryrefswap! || f === Core.memoryrefsetonce! || f === Core.memoryrefreplace!
            # (the value that is stored: the second of the arguments after the reference for `swap` and `setonce`, the third for `replace`)
            key = elem_slot_key(optype(call.args[2]))
            i = f === Core.memoryrefreplace! ? 4 : 3
            key === nothing || (length(call.args) >= i ? store!(key, call.args[i]) : note_slot_store!(key, Any))
        elseif f === Core.memoryrefmodify!
            key = elem_slot_key(optype(call.args[2]))
            key === nothing || note_slot_store!(key, Any) # (what a function that is given gives: not followed)
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
                    for i in 1:fieldcount(S); needs_slot_type(fieldtype(S, i)) && note_slot_store!((:field, S, fieldname(S, i)), Any); end
            else
                key = field_slot_key(S, name)
                key === nothing || (STORE_OPERAND[] = operand; note_slot_store!(key, T))
            end
        elseif f isa Core.IntrinsicFunction && nameof(f) in (:pointerset, :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace)
            # (a store through a pointer to values of an abstract type: into any memory that holds them, and any field of that type)
            P = CC.widenconst(optype(call.args[2]))
            if P isa DataType && P <: Ptr && length(P.parameters) == 1 && P.parameters[1] isa Type && needs_slot_type(P.parameters[1])
                note_slot_store!((:elem, P.parameters[1], nothing), Any)
                note_raw_store!(P.parameters[1])
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
            note_slot_store!((:field, S, fieldname(S, i)), ET)
        end
    end
    return
end

# the stores of a method (its optimized statements, with their types)
function learn_slots!(src::Core.CodeInfo, mi::Core.MethodInstance)
    code = src.code
    called = x -> called_function(code, x)
    optype = x -> slot_operand_type(src, mi, x)
    for pc in eachindex(code)
        st = code[pc]
        call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
        call isa Expr || continue
        if SLOTS_WHY[]
            defs = [string("%", a.id, " = ", first(string(code[a.id]), 150), " :: ", src.ssavaluetypes[a.id]) for a in call.args if a isa Core.SSAValue]
            STORE_CONTEXT[] = string(mi, " #", pc, ": ", first(string(call), 160), "   WHERE ", join(defs, " ; "))
        end
        learn_statement!(call, called, optype)
    end
    return
end

# The stores of a method as they are before the inliner and the scalar replacement have been at it (a `Pair` that only holds the value that is read from a `Dict` for a moment is not there afterwards, and the type of its field is
# read all the same), as facts about the method that are kept, so that the method is not looked at again when it is taken from the cache: (the method, the key of the cache) => the stores as (slot, type)
const SLOT_FACTS = Dict{Tuple{Core.MethodInstance,Int},Vector{Tuple{SlotKey,Any}}}()
const FACTS_SINK = Ref{Union{Nothing,Vector{Tuple{SlotKey,Any}}}}(nothing)
const PASS_PARAMS_KEY = Ref(0)

function record_slot_facts!(ir::CC.IRCode, mi::Core.MethodInstance)
    facts = Tuple{SlotKey,Any}[]
    FACTS_SINK[] = facts
    try
        called = x -> CC.singleton_type(CC.argextype(x, ir))
        optype = x -> CC.widenconst(CC.argextype(x, ir))
        for pc in 1:length(ir.stmts)
            st = ir.stmts[pc][:stmt]
            if SLOTS_WHY[]
                STORE_OPERAND[] = nothing
                STORE_CONTEXT[] = string(mi, " #", pc, ": ", first(string(st), 120))
            end
            st isa Expr && learn_statement!(st, called, optype)
        end
        note_universe_statements!((ir.stmts[pc][:type] for pc in 1:length(ir.stmts)), (ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts)), mi)
        note_slots_in_constants!(ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts))
    finally
        FACTS_SINK[] = nothing
    end
    SLOT_FACTS[(mi, PASS_PARAMS_KEY[])] = facts
    return
end

# The facts of every method that the code that was compiled depends on, which the inlined ones are among (the edges of a method are the methods that it calls and those that were inlined into it)
function replay_reachable_facts!(root::Core.CodeInstance)
    seen = Base.IdSet{Any}()
    stack = Any[root]
    while !isempty(stack)
        ci = pop!(stack)
        ci in seen && continue
        push!(seen, ci)
        ci isa Core.CodeInstance || continue
        ci.def isa Core.MethodInstance && replay_slot_facts!(ci.def)
        for e in ci.edges
            e isa Core.CodeInstance && push!(stack, e)
            e isa Core.MethodInstance && replay_slot_facts!(e)
        end
    end
    return
end

function replay_slot_facts!(mi::Core.MethodInstance)
    facts = get(SLOT_FACTS, (mi, PASS_PARAMS_KEY[]), nothing)
    facts === nothing && return
    for (key, T) in facts
        key[1] === :raw ? push!(RAW_STORE_TYPES, key[2]) : key[1] === :universe ? push!(UNIVERSE_SEEN, key[2]) : key[1] === :truncated ? (SCAN_TRUNCATED[] = true) : note_slot_store!(key, T)
    end
    return
end

note_raw_store!(@nospecialize(T)) = FACTS_SINK[] === nothing ? push!(RAW_STORE_TYPES, T) : push!(FACTS_SINK[], ((:raw, T, nothing), Any))

function CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState{<:OverridesInterpreter}, propagate_inbounds::Bool)
    mi = ir.debuginfo.def
    mi isa Core.MethodInstance && SLOTS_MODE[] !== :off && record_slot_facts!(ir, mi)
    return @invoke CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState, propagate_inbounds::Bool)
end

# What the constants that the code refers to hold in these slots: the elements of an array of `Any`, the fields of a struct that are of an abstract type, and the types of what is in them (for the universe). A constant is
# looked at with a list of what is to be looked at (not by calls of itself: what a program embeds can be a long chain, or deep, as a graph of objects is), each mutable object once (it can refer to itself), and as many objects
# as `SCAN_BUDGET`. One that is larger, or a struct that has more than `SCAN_FIELDS` fields, is noted as such (`note_truncated!`): what it holds is not known, so the slots are not trusted (`analyze_slots!`), and the calls
# on what is read from them are made over the registered types. What is found in a constant is kept for the compilation (`SCAN_CACHE`): the same constant is the operand of many statements.
const SCAN_BUDGET = 200_000
const SCAN_FIELDS = 64
const SCAN_TRUNCATED = Ref(false)
const SCAN_CACHE = IdDict{Any,Vector{Tuple{SlotKey,Any}}}()
note_truncated!() = FACTS_SINK[] === nothing ? (SCAN_TRUNCATED[] = true) : push!(FACTS_SINK[], ((:truncated, nothing, nothing), Any))

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
        elseif isstructtype(typeof(x)) && !(x isa Core.CodeInstance) && !(x isa Core.MethodInstance) && !(x isa Method) && !(x isa Core.TypeName)
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

function note_slots_in!(@nospecialize(x))
    if scan_leaf(x)
        note_universe!(typeof(x))
        return
    end
    facts = get!(() -> scan_facts(x), SCAN_CACHE, x)
    for (key, T) in facts
        k = key[1]
        k === :universe ? note_universe!(key[2]) : k === :truncated ? note_truncated!() : note_slot_store!(key, T)
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

function note_slots_in_constants!(code)
    for st in code
        for a in statement_operands(st)
            v = constant_operand(a)
            v === nothing && continue
            note_slots_in!(v)
        end
    end
    return
end

## the passes

# Run after inference (the types of all that is reached are in the cache, with the optimized code: what `juliac --trim` looks at, so that what is found is of what the program reaches, and does not depend on which methods were
# inferred in this pass and which were taken from the cache): the stores of the slots in the code that the program reaches, and what the reads of them are given in the next pass (`update_slot_types!`), until what is found is
# what was used
function analyze_slots!(interp, root)
    SLOTS_MODE[] === :off && return
    (isempty(SLOT_TYPES) && !dispatch_was_used() && SLOTS_MODE[] !== :observe) && return
    # (what the roots that were made before in this pass stored is kept: a `@cfunction` is a root of its own, and the slots are those of the whole program)
    for (ci, src) in GPUCompiler.CompilerCaching.get_codeinfos(interp, root)
        src isa Core.CodeInfo && ci.def isa Core.MethodInstance || continue
        learn_slots!(src, ci.def)
        note_universe_statements!(src.ssavaluetypes isa Vector ? src.ssavaluetypes : Any[], src.code, ci.def)
        note_slots_in_constants!(src.code)
    end
    replay_reachable_facts!(root)
    if SCAN_TRUNCATED[]
        # (a constant is too large to be looked at all of: what the slots hold is not known, and the program is compiled as if there were no slots)
        @debug "A constant that the program refers to is too large to find what it holds: slots are not used" _id = :static_slots_truncated
        had_types = !isempty(SLOT_TYPES)
        empty!(SLOT_TYPES)
        SLOTS_MODE[] = :off
        had_types && throw(SlotsChanged())
        return
    end
    if !isempty(RAW_STORE_TYPES)
        for k in union(collect(keys(SEEN_SLOTS)), collect(keys(SLOT_TYPES)))
            declared = k[1] === :elem ? k[2] : fieldtype(k[2], k[3])
            declared in RAW_STORE_TYPES && push!(SEEN_UNKNOWN, k)
        end
    end
    SLOTS_MODE[] === :observe && return
    if SLOTS_WHY[]
        if !isempty(UNKNOWN_CENSUS)
            by = Dict{SlotKey,Vector{Int}}() # (slot) => [stores of a type that is not known, of which a parameter of the method]
            example = Dict{SlotKey,String}()
            for (k, param, ctx) in UNKNOWN_CENSUS
                c = get!(by, k, [0, 0]); c[1] += 1; c[2] += param
                haskey(example, k) || (example[k] = ctx)
            end
            println(stderr, "== unknown stores found while looking at the code (all methods): ", length(UNKNOWN_CENSUS), ", of which the value is a parameter of the method: ", count(c -> c[2], UNKNOWN_CENSUS))
            for (k, c) in sort!(collect(by); by = p -> -p[2][1])[1:min(end, 12)]
                println(stderr, "   ", k[1], " ", k[2], " ", k[3], ": ", c[1], " stores, ", c[2], " of a parameter")
                println(stderr, "        e.g. ", first(example[k], 260))
            end
            for (k, param, ctx) in first(UNKNOWN_CENSUS, 6)
                println(stderr, "     e.g. ", param ? "[parameter] " : "", first(ctx, 200))
            end
        end
        println(stderr, "== slots, pass ", SLOT_PASSES[], ": ", length(SLOT_TYPES), " known, ", length(SLOT_OPEN), " open; unknown stores in ", length(SEEN_UNKNOWN), " slots")
        for (k, T) in SEEN_SLOTS
            println(stderr, "   seen ", k[1], " ", k[2], " ", k[3], " => ", T)
        end
        for k in SEEN_UNKNOWN
            println(stderr, "   ", k[1], " ", k[2], " ", k[3], k in SLOT_OPEN ? "  (open already)" : haskey(SLOT_TYPES, k) ? "  (known: $(Base.unionlen(SLOT_TYPES[k])) types)" : "  (not known yet)")
            for w in get(UNKNOWN_STORES, k, String[])
                println(stderr, "        ", first(w, 300))
            end
        end
    end
    changed = update_slot_types!()
    # (the types that the program makes, that a call over an `Any` is made over: the ones found that were not used in this pass are used in the next)
    if UNIVERSE_MODE[] !== :off && dispatch_was_used()
        add_stored_types!()
        new = Any[t for t in UNIVERSE_SEEN if !(t in UNIVERSE_USED)]
        length(UNIVERSE_USED) + length(new) > UNIVERSE_LIMIT && (new = new[1:max(0, UNIVERSE_LIMIT - length(UNIVERSE_USED))])
        if !isempty(new)
            union!(UNIVERSE_USED, new)
            UNIVERSE_VERSION[] += 1
            empty!(UNIVERSE_EXTRAS)
            empty!(REGISTERED_UNIONS)
            changed = true
        end
    end
    changed || return
    SLOT_PASSES[] += 1
    if SLOT_PASSES[] > SLOT_PASS_LIMIT
        # (it does not settle: the compilation is made as if there were no slots)
        empty!(SLOT_TYPES)
        SLOTS_MODE[] = :off
    end
    throw(SlotsChanged())
end

function GPUCompiler.drive_inference!(interp::OverridesInterpreter, mi::Core.MethodInstance)
    root = @invoke GPUCompiler.drive_inference!(interp::CC.AbstractInterpreter, mi::Core.MethodInstance)
    root isa Core.CodeInstance && analyze_slots!(interp, root)
    return root
end

# The types that the reads of the slots are given next, from what was stored in them in the pass that was made: the first time, the types that are known of what was stored (what is stored that is read from a slot
# is of a type that is not known in that pass, as an `Any`, and is not counted); after that, what was stored with the reads as they were given has to be of those types: if it is, they are the ones; if it is of other types, those
# are added; if something that is of a type that is not known is stored, the slot is given up. Returns whether any changed.
function update_slot_types!()
    changed = false
    for (k, T) in SEEN_SLOTS
        k in SLOT_OPEN && continue
        used = get(SLOT_TYPES, k, nothing)
        if used === nothing
            T === Union{} && continue
            SLOT_TYPES[k] = T
            changed = true
        elseif k in SEEN_UNKNOWN
            delete!(SLOT_TYPES, k)
            push!(SLOT_OPEN, k)
            changed = true
        elseif T === Union{} || T === used
            continue
        elseif T <: used
            SLOT_TYPES[k] = T
            changed = true
        else
            new = Union{used, T}
            if Base.unionlen(new) > SLOT_LIMIT[]
                delete!(SLOT_TYPES, k)
                push!(SLOT_OPEN, k)
            else
                SLOT_TYPES[k] = new
            end
            changed = true
        end
    end
    return changed
end

# the type that a read of a slot is given, or `nothing`
# The type of a read from a slot of the types that were stored in it, as precise as what inference had for it before (`rt`): the part of it that is of the types that the declared type has
function refined_read(@nospecialize(T), @nospecialize(rt))
    R = typeintersect(T, CC.widenconst(rt))
    return R === Union{} ? rt : R
end

function slot_read_type(key)
    assumed = get(ASSUMED_SLOTS, key, nothing) # (a type that is stated: see assume.jl)
    assumed === nothing || return assumed
    return SLOTS_MODE[] === :on ? get(SLOT_TYPES, key, nothing) : nothing
end

# What was found, as lines to read: the slot, and the types (or that they are not known)
function slots_report(io::IO = stdout)
    for (key, T) in sort!(collect(SEEN_SLOTS); by = p -> string(p[1]))
        what = key[1] === :elem ? string("elements of Memory{", key[2], "}") : string(key[2], ".", key[3])
        println(io, rpad(what, 60), T === Any ? "NOT KNOWN" : string(Base.unionlen(T), " types: ", T))
    end
end
