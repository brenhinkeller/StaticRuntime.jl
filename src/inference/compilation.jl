# The state of a compilation.
#
# A compilation is made in passes (passes.jl): each infers the program with what the passes before found, and finds more,
# until that settles. All of it is one value, a `Compilation`, made when the compilation starts and gone when it ends:
# nothing of it is left for the next compilation, and compilations share nothing but what is registered (registry.jl).
#
# The compiler's hooks are given the interpreter, not the compilation, so the running compilation is kept where they can
# find it: `compilation()`, set for the extent of `with_compilation` (compilations run one at a time, under a lock). It is
# not a `ScopedValue`: a scope belongs to a task, the compiling task is the root task, and the root task is a constant
# that programs refer to (`Base.roottask`), so the compilation would be copied into the binary as part of its constants.
#
# A compilation holds its `Settings` (from the environment, fixed for all passes), a copy of what is `Registered`, and the
# state of each concern (`ClosureState`, `BoxState`, `SlotState`, `ObjectState`, `DispatchState`): what the pass before
# found, which this pass is inferred with, and what this pass finds, which `begin_pass!` hands to the next.
#
# Inference results are cached per compilation (`cache_key`, `Compilation.id`), and passes reuse what is still right
# (passes.jl). `inference_key`, a hash of all the state that inference reads, is the key when compilations share a cache
# (`STATIC_RUNTIME_CACHE=1`).

## Settings

"""
    Settings

What the environment (`STATIC_RUNTIME_...`, for debugging and the tests) and the limits (`SPLIT_LIMIT`, `DISPATCH_LIMIT`,
`SLOT_LIMIT`) say when a compilation starts.
"""
struct Settings
    strict::Bool
    slots::Symbol                   # slot types: `:on`, `:observe` (found, not used) or `:off` (`STATIC_RUNTIME_SLOTS` = 1, observe, 0)
    slots_fallback::Bool            # a compilation that fails with slot types is made again without (`STATIC_RUNTIME_SLOTS_FALLBACK=0`: not)
    universe::Bool                  # calls over `Any` are also made over the types the program makes (`STATIC_RUNTIME_UNIVERSE=0`: not)
    check_types::Bool               # reads of slots with types are checked (on when `strict`; `STATIC_RUNTIME_CHECK_TYPES`)
    filter_by_methods::Bool         # split only over types that some method fits (`STATIC_RUNTIME_METHOD_FILTER=0`: not)
    precise_nospecializeinfer::Bool # `@nospecializeinfer` is cleared while compiling (`STATIC_RUNTIME_NOSPECIALIZEINFER=0`: not)
    why::Bool                       # `STATIC_RUNTIME_SLOTS_WHY`: say why each slot is given up
    blind::Vector{String}           # (to test the checks) `STATIC_RUNTIME_SLOTS_BLIND=String,Int`: miss the stores of these types
    split_limit::Int
    dispatch_limit::Int
    slot_limit::Int
    share_cache::Bool               # `STATIC_RUNTIME_CACHE=1`: compilations share an inference cache (faster, but not independent)
    objects::Bool                   # constant objects are known one by one (objects.jl; `STATIC_RUNTIME_OBJECTS=0`: not)
    reuse::Bool                     # passes reuse what is still right (passes.jl; `STATIC_RUNTIME_REUSE=0`: not)
end

function Settings(; strict::Bool = true)
    mode = get(ENV, "STATIC_RUNTIME_SLOTS", "on")
    check = get(ENV, "STATIC_RUNTIME_CHECK_TYPES", "")
    return Settings(strict,
                    mode == "0" ? :off : mode == "observe" ? :observe : :on,
                    get(ENV, "STATIC_RUNTIME_SLOTS_FALLBACK", "1") != "0",
                    get(ENV, "STATIC_RUNTIME_UNIVERSE", "1") != "0",
                    isempty(check) ? strict : check != "0", # (on when the compilation is `strict`, and `1` or `0` say it for either)
                    get(ENV, "STATIC_RUNTIME_METHOD_FILTER", "1") != "0",
                    get(ENV, "STATIC_RUNTIME_NOSPECIALIZEINFER", "1") != "0",
                    haskey(ENV, "STATIC_RUNTIME_SLOTS_WHY"),
                    String[s for s in split(get(ENV, "STATIC_RUNTIME_SLOTS_BLIND", ""), ',') if !isempty(s)],
                    SPLIT_LIMIT[], DISPATCH_LIMIT[], SLOT_LIMIT[],
                    get(ENV, "STATIC_RUNTIME_CACHE", "0") == "1",
                    get(ENV, "STATIC_RUNTIME_OBJECTS", "1") != "0",
                    get(ENV, "STATIC_RUNTIME_REUSE", "1") != "0")
end

# (`hash` of a struct that has a `Vector` is not that of what is in it)
Base.hash(s::Settings, h::UInt) = foldl((h, name) -> hash(getfield(s, name), h), fieldnames(Settings); init = h)

## Tracing
#
# `STATIC_RUNTIME_TRACE=1` writes what each pass found and spent its time on to the standard error. Other values add:
# - `methoderrors`: calls with no method for the types that reach them (mostly on paths union splitting leaves untaken);
# - `embed`: why each object that can not be copied into the binary can not, with its path from a constant;
# - `ir:<text>`: the optimized code of each method whose `MethodInstance` text contains `<text>`.
# It is read once per compilation (`Trace`; not part of the `Settings`, since it does not change what is compiled).
struct Trace
    on::Bool
    methoderrors::Bool
    embed::Bool
    ir::String # (`""`: none)
end
function Trace(v::AbstractString = get(ENV, "STATIC_RUNTIME_TRACE", "0"))
    on = !(v == "0" || isempty(v))
    return Trace(on, v == "methoderrors", v == "embed", startswith(v, "ir:") ? String(v[4:end]) : "")
end
# (that of the running compilation, or of the environment outside of one: the runtime's linker is also used alone)
current_trace() = (c = CURRENT_COMPILATION[]; c === nothing ? Trace() : c.trace)
trace_on() = current_trace().on
trace_method_errors_on() = current_trace().methoderrors
trace_embed_on() = current_trace().embed
trace(args...) = (println(stderr, "[static-runtime] ", args...); nothing)

## The state of each concern
#
# Each concern keeps what the pass before found (what this pass is inferred with, and so part of its key) and what this
# pass finds (cleared by `begin_pass!`). Fields marked "compilation" keep their contents across passes.

const BoxKey = Tuple{Any,Union{Int,Symbol}} # (method specialization, box number) or (closure type, field name)

"Functions that unknown calls are made over (closures.jl), callbacks and listeners, and `@cfunction`s (cfunctions.jl)."
Base.@kwdef mutable struct ClosureState
    functions::Vector{Type} = Type[]                                  # the candidate function types of unknown calls
    callbacks::Vector{Tuple{Type,Type}} = Tuple{Type,Type}[]          # (value type, function type) pairs, see `note_callback`
    listener_objects::Dict{Any,Tuple} = Dict{Any,Tuple}()             # value type => the listeners that code compares with
    listener_types::Set{Any} = Set{Any}()                             # the types of all listeners found
    listeners_complete::Bool = true                                   # the scan of the constants found them all
    all_listeners::Tuple = ()                                         # all compared listeners, of any value type (`()` if too many)
    found_listeners::Dict{Any,Vector{Any}} = Dict{Any,Vector{Any}}()  # (compilation) the listeners of the constants, by value type
    found_listener_ids::Set{Tuple{Any,UInt}} = Set{Tuple{Any,UInt}}() # (compilation)
    listener_holders::IdDict{Any,Bool} = IdDict{Any,Bool}()           # (compilation) `holds_listeners` of each type
    cfunction_roots::Vector{Runtime.CFunctionRoot} = Runtime.CFunctionRoot[] # the `@cfunction`s, and the functions that they call:
    cfunction_functions::Vector{Any} = Any[]
    # found in this pass
    seen_functions::Vector{Type} = Type[]
    seen_functions_set::Set{Type} = Set{Type}()
    seen_callbacks::Vector{Tuple{Type,Type}} = Tuple{Type,Type}[]
    seen_cfunctions::Vector{Tuple{DataType,Vector{DataType},DataType,Any}} = Tuple{DataType,Vector{DataType},DataType,Any}[] # (function type, argument types, result type, function)
    dispatch_requested::Bool = false                                  # an unknown call was seen
    union_used::Bool = false                                          # a call was made over the candidates
    callback_call_requested::Bool = false
    box_function_seen::Bool = false                                   # a constant's `Core.Box` holds a function (its type is not known from reads)
    sink::Any = nothing                                               # the `InferenceFindings` of the code being optimized
    optimized::Int = 0                                                # (trace) methods optimized in this pass
    optimized_unique::Set{Any} = Set{Any}()
    slowest::Vector{Tuple{Float64,Any,Int}} = Tuple{Float64,Any,Int}[] # (trace) (seconds, method, statements) of the slowest to optimize
end
function begin_pass!(cl::ClosureState)
    empty!(cl.seen_functions); empty!(cl.seen_functions_set); empty!(cl.seen_callbacks); empty!(cl.seen_cfunctions)
    cl.dispatch_requested = cl.union_used = cl.callback_call_requested = cl.box_function_seen = false
    cl.optimized = 0; empty!(cl.optimized_unique); empty!(cl.slowest)
    return cl
end

"The types of what the boxes of closures hold (boxes.jl)."
Base.@kwdef mutable struct BoxState
    types::Dict{BoxKey,Any} = Dict{BoxKey,Any}()
    gave_up::Set{BoxKey} = Set{BoxKey}()                              # boxes whose type is not known: they stay `Core.Box`
    seen::Dict{BoxKey,Any} = Dict{BoxKey,Any}()                       # found in this pass
    slot_numbers::Dict{Any,Dict{Int,Int}} = Dict{Any,Dict{Int,Int}}() # (compilation) box number of each slot of a method's code
end
begin_pass!(bx::BoxState) = (empty!(bx.seen); bx)

"The types held by slots of abstract types (slots.jl), and the universe of types that the program makes."
Base.@kwdef mutable struct SlotState
    mode::Symbol                                                      # from the settings; made `:off` if the types do not settle
    fell_back::Bool = false                                           # the compilation was made again without slot types
    passes::Int = 0
    types::Dict{SlotKey,Any} = Dict{SlotKey,Any}()                    # what reads of each slot are given in this pass
    open::Set{SlotKey} = Set{SlotKey}()                               # slots given up: reads are `Any`
    universe::Set{Any} = Set{Any}()                                   # the types that a call over `Any` is made over
    universe_extras::Dict{Any,Vector{Any}} = Dict{Any,Vector{Any}}()  # (the subtypes of a type among them, once asked)
    type_slots::Bool = false                                          # some of `types` are slots of types (`Vector{Type}`)
    type_values::Vector{Any} = Any[]                                  # the types that slots of types hold
    holds_types::Dict{SlotKey,Bool} = Dict{SlotKey,Bool}()            # (whether each slot holds types, once asked)
    # found in this pass
    seen::Dict{SlotKey,Any} = Dict{SlotKey,Any}()                     # the union of what was stored in each slot
    seen_members::Dict{SlotKey,Vector{Any}} = Dict{SlotKey,Vector{Any}}() # stored types not yet in `seen` (see `note_slot_store!`)
    seen_unknown::Set{SlotKey} = Set{SlotKey}()                       # slots that something of an unknown type was stored in
    universe_seen::Set{Any} = Set{Any}()
    stored_by_slot::Dict{SlotKey,Set{Any}} = Dict{SlotKey,Set{Any}}() # (see `note_stored_type!`)
    raw_store_types::Set{Any} = Set{Any}()                            # declared types that a store through a pointer writes
    scan_truncated::Bool = false                                      # a constant was too large to scan
    scan_cache::IdDict{Any,Vector{Tuple{SlotKey,Any}}} = IdDict{Any,Vector{Tuple{SlotKey,Any}}}() # what each constant holds
    # while the facts of a method are recorded (see `record_slot_facts!`)
    facts_sink::Union{Nothing,Vector{Tuple{SlotKey,Any}}} = nothing
    fact_mi::Any = nothing
    current_result::Any = nothing                                     # the `InferenceResult` being optimized
    # how types flow into slots through method arguments (see `resolve_argument_stores!`), keyed by (method instance,
    # argument)
    argstores::Dict{Any,Set{Any}} = Dict{Any,Set{Any}}()              # => the slots it is stored in
    argpasses::Dict{Any,Set{Any}} = Dict{Any,Set{Any}}()              # => the (method instance, argument)s that pass theirs to it
    callargs::Dict{Any,Vector{Any}} = Dict{Any,Vector{Any}}()         # => the types that calls give it
    # for `STATIC_RUNTIME_SLOTS_WHY`
    unknown_stores::Dict{SlotKey,Vector{String}} = Dict{SlotKey,Vector{String}}()
    unknown_census::Vector{Tuple{SlotKey,Bool,String}} = Tuple{SlotKey,Bool,String}[]
    store_context::Any = nothing
    store_operand::Any = nothing
end
SlotState(mode::Symbol) = SlotState(; mode)
function begin_pass!(s::SlotState)
    empty!(s.seen); empty!(s.seen_members); empty!(s.seen_unknown); empty!(s.universe_seen); empty!(s.stored_by_slot)
    empty!(s.raw_store_types); s.scan_truncated = false
    empty!(s.argstores); empty!(s.argpasses); empty!(s.callargs); empty!(s.unknown_stores)
    return s
end

"An object, compared and hashed by identity."
struct ObjRef
    x::Any
end
Base.:(==)(a::ObjRef, b::ObjRef) = a.x === b.x
Base.hash(a::ObjRef, h::UInt) = hash(objectid(a.x), h)

"What is known of the objects that are constants of the program (objects.jl and object_calls.jl)."
Base.@kwdef mutable struct ObjectState
    ready::Bool = false                                               # the facts of a pass before are there
    wanted::Bool = false                                              # a read in this pass could have been known with them
    once_wanted::Bool = false                                         # (compilation) `wanted` in some pass
    folds::Int = 0                                                    # (trace) reads known in this pass
    # the fields that code writes: (type, name), (type, :*) for any field, (nothing, name) for that field of any type
    written::Set{Tuple{Any,Symbol}} = Set{Tuple{Any,Symbol}}()
    written_any::Bool = false
    use_written::Set{Tuple{Any,Symbol}} = Set{Tuple{Any,Symbol}}()    # (those of the pass before)
    # what inference asked of the facts, and so depends on (see `objects_hash`)
    asked_written::Set{Tuple{Any,Symbol}} = Set{Tuple{Any,Symbol}}()  # (compilation)
    asked_fields::Set{Tuple{ObjRef,Symbol}} = Set{Tuple{ObjRef,Symbol}}() # (compilation)
    # what is stored in fields of objects (see "Stores in objects" in objects.jl)
    stores::Dict{Tuple{ObjRef,Symbol},Any} = Dict{Tuple{ObjRef,Symbol},Any}()       # (object, field) => stored types
    unattributed::Dict{Tuple{Any,Symbol},Any} = Dict{Tuple{Any,Symbol},Any}()       # (type, field) => stored in an unknown object
    unknown::Set{Any} = Set{Any}()                                    # fields that something of an unknown type was stored in
    use_stores::Dict{Tuple{ObjRef,Symbol},Any} = Dict{Tuple{ObjRef,Symbol},Any}()
    use_unattributed::Dict{Tuple{Any,Symbol},Any} = Dict{Tuple{Any,Symbol},Any}()
    use_unknown::Set{Any} = Set{Any}()
    recvstores::Dict{Tuple{Any,Int},Vector{Tuple{Any,Symbol,Any}}} = Dict{Tuple{Any,Int},Vector{Tuple{Any,Symbol,Any}}}() # (mi, n) => stores in argument n: (path, field, value)
    callsites::Dict{Any,Vector{Tuple{Any,Vector{Any},Vector{Any}}}} = Dict{Any,Vector{Tuple{Any,Vector{Any},Vector{Any}}}}() # mi => (caller, arguments, argument types)
    invoked::Set{Any} = Set{Any}()                                    # method instances that a call left in the code calls
    direct::Dict{Any,Vector{Tuple{Symbol,Any,Any,Any}}} = Dict{Any,Vector{Tuple{Symbol,Any,Any,Any}}}() # mi => its stores in objects
    holds::IdDict{Any,Bool} = IdDict{Any,Bool}()                      # (compilation) `holds_object_slots` of each type
    gives::IdDict{Any,Bool} = IdDict{Any,Bool}()                      # (compilation) `gives_object` of each signature
    # while the facts are recorded from a method's code after inlining (`record_object_facts!`), and replayed
    recording::Bool = false
    pending_facts::Any = nothing
    pending_mi::Any = nothing
    replaying::Any = nothing
    # (compilation) per-object code (object_calls.jl)
    keyed_objects::Vector{Any} = Any[]                                # the object of each `ObjectKey{N}`
    key_index::IdDict{Any,Int} = IdDict{Any,Int}()
    call_methods::Dict{Tuple{Any,UInt},Any} = Dict{Tuple{Any,UInt},Any}() # `object_call_method` of each signature and world
    keyable::IdDict{Any,Bool} = IdDict{Any,Bool}()                    # `keyable_type` of each type
    remakers::Dict{Tuple{Any,Symbol},Any} = Dict{Tuple{Any,Symbol},Any}() # (compilation) `remade_by` of each field (boxes.jl)
end
function begin_pass!(o::ObjectState)
    empty!(o.written); o.written_any = o.wanted = false; o.folds = 0
    empty!(o.stores); empty!(o.unattributed); empty!(o.unknown); empty!(o.recvstores); empty!(o.callsites); empty!(o.invoked); empty!(o.direct)
    return o
end

"Calls made over the registered types (dispatch.jl)."
Base.@kwdef mutable struct DispatchState
    registered_used::Bool = false                                     # this pass made one
    used_in::Set{Any} = Set{Any}()                                    # (compilation) the methods whose code made one
    registered_calls::Dict{Tuple{Any,Vector{Any}},Int} = Dict{Tuple{Any,Vector{Any}},Int}() # (for the message)
    unions::Dict{Any,Any} = Dict{Any,Any}()                           # `registered_union` of each type, for this pass
    signatures::Dict{Tuple{UInt,Any,Int},Union{Nothing,Vector{Any}}} = Dict{Tuple{UInt,Any,Int},Union{Nothing,Vector{Any}}}() # method signatures of a function
end
begin_pass!(d::DispatchState) = (d.registered_used = false; empty!(d.unions); d)

## The compilation

Base.@kwdef mutable struct Compilation
    settings::Settings = Settings()
    registered::Registered = Registered()                             # a copy of what is registered (registry.jl)
    trace::Trace = Trace()                                            # what `STATIC_RUNTIME_TRACE` says, read when the compilation starts
    id::Int = new_compilation_id(settings)                            # the name of this compilation's inference cache (see `purge_inferred!`)
    pass::Int = 0
    closures::ClosureState = ClosureState(callbacks = copy(registered.callbacks)) # (callbacks registered before the program)
    boxes::BoxState = BoxState()
    slots::SlotState = SlotState(settings.slots)
    dispatch::DispatchState = DispatchState()
    objects::ObjectState = ObjectState()
    key::Int = inference_key(settings, registered, closures, boxes, slots, objects) # of this pass
    # what passes take from the passes before (passes.jl)
    inferred::Vector{Tuple{Core.MethodInstance,Any}} = Tuple{Core.MethodInstance,Any}[] # the method instances inferred, with their owners
    answers::Any = nothing                                            # `PassAnswers` of this pass
    deps_lost::Bool = false                                           # a question was asked outside of any method
    orphan_deps::IdDict{Any,Dict{Any,Any}} = IdDict{Any,Dict{Any,Any}}() # questions of constant frames that have no caller
    # caches and side effects of the compilation
    nospecializeinfer::Vector{Method} = Method[]                      # methods whose `@nospecializeinfer` is cleared (see `restore_nospecializeinfer!`)
    libraries::Base.RefValue{Runtime.LibraryPlan} = Ref(Runtime.LibraryPlan()) # the libraries that the program calls, once linked
    closed_subtypes::Dict{Tuple{Any,UInt,Int},Any} = Dict{Tuple{Any,UInt,Int},Any}() # (see `listed_union`)
    user_modules::Dict{Module,Bool} = Dict{Module,Bool}()             # (see `user_module`)
    julia_owned::Dict{Module,Bool} = Dict{Module,Bool}()              # (see `julia_owned_module`)
    warnings::Vector{Pair{Any,String}} = Pair{Any,String}[]           # said when the compilation ends (see `compile_warning!`)
end

Compilation(settings::Settings, registered::Registered = Registered()) = Compilation(; settings, registered)

# The name of a compilation's inference cache: unique (time, process and count, so that code instances made by the
# precompile workload, in another process, are never found), or `0`, shared by all, with `STATIC_RUNTIME_CACHE=1`.
const COMPILATION_COUNT = Threads.Atomic{Int}(0)
new_compilation_id(settings::Settings) = settings.share_cache ? 0 : Int(hash((time_ns(), getpid(), Threads.atomic_add!(COMPILATION_COUNT, 1))) >> 1)

# A warning found during inference, said once when the compilation ends (a `@generated` function's code runs during
# inference, where writing to a terminal would switch tasks, which is not allowed there).
function compile_warning!(key, message::AbstractString)
    c = CURRENT_COMPILATION[]
    c === nothing && return nothing
    any(w -> isequal(first(w), key), c.warnings) || push!(c.warnings, Pair{Any,String}(key, String(message)))
    return nothing
end
function say_warnings!(c::Compilation)
    for (_, message) in c.warnings
        @warn message
    end
    empty!(c.warnings)
    return nothing
end

const CURRENT_COMPILATION = Ref{Union{Nothing,Compilation}}(nothing)
const COMPILATION_LOCK = ReentrantLock()
const LAST_COMPILATION = Ref{Union{Nothing,Compilation}}(nothing) # (only for looking at what the last compilation found: `slots_report`)

"""
    compilation() -> Compilation

The compilation that is made now. (It is an error to ask outside of one: the hooks of inference are only run by a
compilation.)
"""
function compilation()
    c = CURRENT_COMPILATION[]
    c === nothing && error("there is no compilation: the state of one is only there while a compilation of this package is made (`compile_executable` and the other entry points)")
    return c
end

"Run `f(c)` with the compilation `c` that is made for it, and put back what was changed in the methods of Julia (`@nospecializeinfer`) and the compilation that was made before (if there was one), when it ends, however it does."
function with_compilation(f; strict::Bool = true)
    lock(COMPILATION_LOCK) do
        # (a compilation is made of what it is given and of what was registered, and of nothing that another compilation
        # left: what it finds is in the compilation, and what inference made is not found by another)
        c = Compilation(Settings(; strict))
        previous = CURRENT_COMPILATION[]
        CURRENT_COMPILATION[] = c
        LAST_COMPILATION[] = c
        try
            return f(c)
        finally
            CURRENT_COMPILATION[] = previous
            restore_nospecializeinfer!(c)
            purge_inferred!(c)
            say_warnings!(c)
        end
    end
end

## The key of the inference cache

# A hash of a type that is the same in every process (an `objectid` is not), so that what the precompile workload infers
# is found by the sessions that load the package. `hash` of a `Union` is the same for all unions, so unions, and types
# with unions among their parameters (`Tuple{Union{A,B}}`), are hashed by their parts.
function type_hash(@nospecialize(T))
    T isa Union && return hash(sort!(UInt[type_hash(t) for t in Base.uniontypes(T)]))
    if T isa DataType && !isempty(T.parameters)
        h = hash(T.name.name, hash(nameof(T.name.module)))
        for p in T.parameters
            h = hash(p isa Type ? type_hash(p) : p, h)
        end
        return h
    end
    return hash(T)
end

# what the types of the slots are, and what the universe is (both are sets: the order does not matter)
function slots_hash(s::SlotState)
    h = UInt(0)
    for (k, T) in s.types
        h += hash(type_hash(T), hash(type_hash(k[2]), hash(k[1], hash(k[3]))))
    end
    u = UInt(0)
    for t in s.universe
        u += type_hash(t)
    end
    return hash(s.mode, hash(length(s.types), hash(h, hash(length(s.universe), u))))
end

function boxes_hash(b::BoxState)
    h = UInt(0)
    for ((k, n), T) in b.types
        h += hash(type_hash(T), hash(n, type_hash(k)))
    end
    return hash(length(b.types), h)
end

# (the candidate functions, in the order found, which the unions are made in; the callbacks and compared listeners)
function closures_hash(cl::ClosureState)
    h = foldl((h, T) -> hash(type_hash(T), h), cl.functions; init = UInt(0))
    h = hash(length(cl.functions), h)
    h = foldl((h, (V, F)) -> hash(type_hash(F), hash(type_hash(V), h)), cl.callbacks; init = h)
    # (the listeners that the code compares with, by their identity: of this compilation)
    for (V, fs) in cl.listener_objects; h += hash(map(objectid, fs), type_hash(V)); end
    h = hash(map(objectid, cl.all_listeners), h)
    return hash(length(cl.callbacks), h)
end

"""
    inference_key(c::Compilation) -> Int

The number that the inference of this pass of the compilation is kept apart by (the parameters of the job: see
`OverridesParams`): a hash of all that it is made with. Each state that inference reads is in it, by what it *is*, and
in a way that is the same in every process (`type_hash`).
"""
inference_key(c::Compilation) = inference_key(c.settings, c.registered, c.closures, c.boxes, c.slots, c.objects)
function inference_key(settings::Settings, registered::Registered, closures::ClosureState, boxes::BoxState, slots::SlotState, objects::ObjectState)
    h = hash(settings)
    h = hash(registered.version, h)
    h = hash(closures_hash(closures), h)
    h = hash(boxes_hash(boxes), h)
    h = hash(slots_hash(slots), h)
    h = hash(objects_hash(objects), h)
    return h % Int
end

# (the answers to what inference asked of the object facts, not all of the facts, which change as more code is reached.
# What is asked only grows, so equal keys mean equal questions with equal answers. Before the facts exist, or if no read
# could ever use them (`once_wanted`), the objects add nothing to the key.)
function objects_hash(o::ObjectState)
    (o.ready && (o.once_wanted || !isempty(o.asked_written) || !isempty(o.asked_fields))) || return UInt(0)
    h = UInt(1)
    for (S, name) in o.asked_written; h += hash(written_in(o.use_written, S, name), hash(name, S === nothing ? UInt(2) : type_hash(S))); end
    for (r, name) in o.asked_fields; h += hash(field_answer_hash(field_answer(o.use_stores, o.use_unattributed, o.use_unknown, r, name)), hash(name, objectid(r.x))); end
    return hash(length(o.asked_written) + length(o.asked_fields), h)
end
field_answer_hash(@nospecialize(a)) = a === nothing ? UInt(3) : type_hash(a)

"""
    cache_key(c::Compilation) -> Int

The key of the cache of inference of the compilation (the parameters of its jobs, see `OverridesParams`): the same for
all of its passes, which take from it what is still right (see passes.jl), and made of what is the same for the whole
compilation (the settings, what is registered). With a cache that compilations share (`STATIC_RUNTIME_CACHE=1`), it is
the key of the pass, all of the state (`inference_key`), as two compilations take each other's results by it.
"""
cache_key(c::Compilation) = c.settings.share_cache ? c.key : hash(c.registered.version, hash(c.settings)) % Int
