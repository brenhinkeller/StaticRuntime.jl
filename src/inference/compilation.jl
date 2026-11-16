# The state of a compilation.
#
# What inference does with a program is found over several passes (see `with_function_candidates_passes`): each pass infers the program with what the passes before it found (the types of the functions that the code has, the
# types that the slots hold, the types of the boxes), and finds more, until what is found is what was used. All of that is the state of ONE compilation, and it is one value, a `Compilation`, which is made when the compilation
# starts and is gone when it ends: nothing of a compilation is left for the next one to find, and two compilations do not share anything but the caches that are kept for the key of what they infer (see below).
#
# The hooks that are methods of the functions of the compiler (`abstract_call_gf_by_type`, `optimize`, ...) are given the interpreter and not a compilation, so the compilation that is made now is kept where they can find it:
# `compilation()`. It is set for the dynamic extent of `with_compilation` and put back (to what it was, which is another compilation if this one is inside it) however that ends, and the compilations are made one at a time
# (a lock: Julia's own inference is). It is not a `ScopedValue`, which is what is made for this: a scope is the value of a task, and the task that compiles is the root task of the process, which is a constant of the programs that
# are compiled (code that waits, or makes a process, refers to `Base.roottask`): the program is given the objects that its constants refer to, so the compilation, and all that it has found, would have been in the scope
# that the binary got a copy of, and looked at by the analysis of the constants as part of the program.
#
# What a compilation is made of:
#
# * `Settings`: what the environment and the limits say, read when it starts, and the same for all its passes;
# * `Registered`: a copy of what is registered (see registry.jl) when it starts;
# * the state of the concerns that find things while they infer, one for each (`ClosureState`, `BoxState`, `SlotState`, `DispatchState`), each with what it was found to be before this pass (that this pass is made with, and
#   that its key is made of) and what this pass has found (that is the next one's, `begin_pass!` clears it).
#
# GPUCompiler keeps what is inferred apart for the *parameters* of the job (they are in the token that owns the code instances, and two tokens are the same if the parameters are the same values): so everything that
# inference depends on has to be in them, and they are the key of the cache, a number made of all of it (`inference_key`). It is made of what is, and not of a counter that says that something changed: two compilations that
# are at the same state have the same key, and so share what they inferred, and no state that the key does not have can change what is inferred.

## Settings

"""
    Settings

What is read from the environment (the variables `STATIC_RUNTIME_...`, which are for finding bugs and for the tests) and from the limits (`SPLIT_LIMIT`, `DISPATCH_LIMIT`), when a compilation starts.
"""
struct Settings
    strict::Bool
    slots::Symbol                   # `:on` (the types of the slots are used), `:observe` (found, and not used), `:off`: `STATIC_RUNTIME_SLOTS` is unset or `1`, `observe`, `0`
    slots_fallback::Bool            # a compilation that fails with the types of the slots is made once more without them (`STATIC_RUNTIME_SLOTS_FALLBACK=0`: not)
    universe::Bool                  # the types that the program makes are types that a call over an `Any` is made over (`STATIC_RUNTIME_UNIVERSE=0`: not)
    check_types::Bool               # what is read from a slot is checked to be of the types that were stored (on when `strict`; `STATIC_RUNTIME_CHECK_TYPES`)
    filter_by_methods::Bool         # `STATIC_RUNTIME_METHOD_FILTER=0` turns it off
    precise_nospecializeinfer::Bool # `STATIC_RUNTIME_NOSPECIALIZEINFER=0` leaves the methods as they are
    why::Bool                       # `STATIC_RUNTIME_SLOTS_WHY`: says why a slot is given up
    blind::Vector{String}           # for testing the check: `STATIC_RUNTIME_SLOTS_BLIND=String,Int` makes the analysis miss the stores of these types
    split_limit::Int
    dispatch_limit::Int
    slot_limit::Int
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
                    SPLIT_LIMIT[], DISPATCH_LIMIT[], SLOT_LIMIT[])
end

# (`hash` of a struct that has a `Vector` is not that of what is in it)
Base.hash(s::Settings, h::UInt) = foldl((h, name) -> hash(getfield(s, name), h), fieldnames(Settings); init = h)

## Tracing
#
# `STATIC_RUNTIME_TRACE=1` says on the error output what each pass of a compilation found and spent its time on: nothing is written otherwise. `STATIC_RUNTIME_TRACE=methoderrors` says the same, and
# lists the calls that have no method for the types that reach them too (most of them are on paths that are never taken: they are what union splitting leaves). (It is not in the `Settings`: it does not
# change what is compiled.)
trace_on() = (v = get(ENV, "STATIC_RUNTIME_TRACE", "0"); v != "0" && v != "")
trace_method_errors_on() = get(ENV, "STATIC_RUNTIME_TRACE", "") == "methoderrors"
trace(args...) = (println(stderr, "[static-runtime] ", args...); nothing)

## The state of each concern

const BoxKey = Tuple{Any,Union{Int,Symbol}} # (the specialization of a method, the number of the box among those that its code makes), or (the type of a closure, the name of its field that is a box)

"What the passes know of the functions that the code has (closures.jl) and of the `@cfunction`s (cfunctions.jl): the candidates that a call of a function that is not known is made over, and what this pass has seen."
mutable struct ClosureState
    functions::Vector{Type}                                                # the types of functions that a call of an unknown function is made over
    callbacks::Vector{Tuple{Type,Type}}                                    # (the type of the value, the type of the function) of `note_callback`
    cfunction_roots::Vector{Runtime.CFunctionRoot}                         # the `@cfunction`s of the program, with the functions that they call (`cfunction_functions`, in the same order)
    cfunction_functions::Vector{Any}
    # found in this pass
    seen_functions::Vector{Type}
    seen_functions_set::Set{Type}
    seen_callbacks::Vector{Tuple{Type,Type}}
    seen_cfunctions::Vector{Tuple{DataType,Vector{DataType},DataType,Any}} # (the type of the function, of the arguments, of the result, the function)
    dispatch_requested::Bool                                               # a call of a function that is not known has been looked at
    union_used::Bool                                                       # a call has been made over the candidates
    callback_call_requested::Bool
    optimized::Int                                                         # (for `STATIC_RUNTIME_TRACE`) the methods that were optimized in this pass, and which of them
    optimized_unique::Set{Any}
    box_function_seen::Bool                                                # a function is in a `Core.Box` that a constant has (the variable of a closure that is made by code that is not compiled): its type is not known by any read of the box
end
ClosureState() = ClosureState(Type[], Tuple{Type,Type}[], Runtime.CFunctionRoot[], Any[], Type[], Set{Type}(), Tuple{Type,Type}[],
                              Tuple{DataType,Vector{DataType},DataType,Any}[], false, false, false, 0, Set{Any}(), false)

"What the passes know of the boxes of the closures (boxes.jl): the type of what each holds, as the last pass found it."
mutable struct BoxState
    types::Dict{BoxKey,Any}
    gave_up::Set{BoxKey}                     # the boxes whose type could not be found: they stay `Core.Box`
    seen::Dict{BoxKey,Any}                   # found in this pass
    slot_numbers::Dict{Any,Dict{Int,Int}}    # the number of the box that a slot is, for the code of a method (what the code has does not change in a compilation)
end
BoxState() = BoxState(Dict{BoxKey,Any}(), Set{BoxKey}(), Dict{BoxKey,Any}(), Dict{Any,Dict{Int,Int}}())

"What the passes know of the slots that hold values of an abstract type (slots.jl), and of the universe: the types that the program makes."
mutable struct SlotState
    mode::Symbol                             # the one of the settings, until it is made `:off` (what was found does not settle, or is not known)
    fell_back::Bool                          # a compilation that failed with the types of the slots was made again without them
    passes::Int
    types::Dict{SlotKey,Any}                 # the types that reads of each slot are given in this pass (see `update_slot_types!`)
    open::Set{SlotKey}                       # the slots that are given up: what is stored in them is not known, and a read of one is an `Any`
    universe::Set{Any}                       # the types of the universe that a call over an `Any` is made over in this pass
    universe_extras::Dict{Any,Vector{Any}}   # (those that are subtypes of a type, once asked)
    # found in this pass
    seen::Dict{SlotKey,Any}                  # the types that were stored in each slot: the union of them, or `Any` when something of a type that is not known was
    seen_unknown::Set{SlotKey}               # the slots that something of a type that is not known was stored in
    universe_seen::Set{Any}
    stored_by_slot::Dict{SlotKey,Set{Any}}   # the types that were stored in each slot (those of the slots that are open are in the universe: see `note_stored_type!`)
    raw_store_types::Set{Any}                # the declared types of the slots that a store through a pointer was seen to write
    scan_truncated::Bool                     # a constant is too large to look at all of
    scan_cache::IdDict{Any,Vector{Tuple{SlotKey,Any}}}   # what is found in a constant (the same constant is the operand of many statements)
    facts_sink::Union{Nothing,Vector{Tuple{SlotKey,Any}}} # where the stores that are found go, while the facts of a method are recorded (see `record_slot_facts!`)
    # for `STATIC_RUNTIME_SLOTS_WHY`
    unknown_stores::Dict{SlotKey,Vector{String}}
    unknown_census::Vector{Tuple{SlotKey,Bool,String}}
    store_context::Any
    store_operand::Any
end
SlotState(mode::Symbol) = SlotState(mode, false, 0, Dict{SlotKey,Any}(), Set{SlotKey}(), Set{Any}(), Dict{Any,Vector{Any}}(),
                                    Dict{SlotKey,Any}(), Set{SlotKey}(), Set{Any}(), Dict{SlotKey,Set{Any}}(), Set{Any}(), false,
                                    IdDict{Any,Vector{Tuple{SlotKey,Any}}}(), nothing,
                                    Dict{SlotKey,Vector{String}}(), Tuple{SlotKey,Bool,String}[], nothing, nothing)

"The calls over the registered types (dispatch.jl): whether this pass made any, and which, for the message that says so; and what was looked up to make them."
mutable struct DispatchState
    registered_used::Bool
    registered_calls::Dict{String,Int}
    unions::Dict{Any,Any}                    # `registered_union` of a type: the same for a whole pass
    signatures::Dict{Tuple{UInt,Any,Int},Union{Nothing,Vector{Any}}} # the signatures of the methods of a function (it depends on the method table that this compilation looks them up in)
end
DispatchState() = DispatchState(false, Dict{String,Int}(), Dict{Any,Any}(), Dict{Tuple{UInt,Any,Int},Union{Nothing,Vector{Any}}}())

## The compilation

mutable struct Compilation
    settings::Settings
    registered::Registered
    pass::Int
    key::Int                                 # the key of the inference cache of this pass (`inference_key`)
    closures::ClosureState
    boxes::BoxState
    slots::SlotState
    dispatch::DispatchState
    nospecializeinfer::Vector{Method}        # the methods whose `@nospecializeinfer` was cleared for as long as the compilation runs (see `restore_nospecializeinfer!`)
    libraries::Base.RefValue{Runtime.LibraryPlan} # the libraries that the program calls, when it has been linked (`libraries = :bundle` copies them)
end

function Compilation(settings::Settings = Settings(), registered::Registered = Registered())
    c = Compilation(settings, registered, 0, 0, ClosureState(), BoxState(), SlotState(settings.slots), DispatchState(), Method[], Ref(Runtime.LibraryPlan()))
    append!(c.closures.callbacks, registered.callbacks) # (those that exist before the program: see `add_callback!`)
    c.key = inference_key(c)
    return c
end

const CURRENT_COMPILATION = Ref{Union{Nothing,Compilation}}(nothing)
const COMPILATION_LOCK = ReentrantLock()
const LAST_COMPILATION = Ref{Union{Nothing,Compilation}}(nothing) # (only for looking at what the last compilation found: `slots_report`)

"""
    compilation() -> Compilation

The compilation that is made now. (It is an error to ask outside of one: the hooks of inference are only run by a compilation.)
"""
function compilation()
    c = CURRENT_COMPILATION[]
    c === nothing && error("there is no compilation: the state of one is only there while a compilation of this package is made (`compile_executable` and the other entry points)")
    return c
end

"Run `f(c)` with the compilation `c` that is made for it, and put back what was changed in the methods of Julia (`@nospecializeinfer`) and the compilation that was made before (if there was one), when it ends, however it does."
function with_compilation(f; strict::Bool = true)
    c = Compilation(Settings(; strict))
    lock(COMPILATION_LOCK) do
        previous = CURRENT_COMPILATION[]
        CURRENT_COMPILATION[] = c
        LAST_COMPILATION[] = c
        try
            return f(c)
        finally
            CURRENT_COMPILATION[] = previous
            restore_nospecializeinfer!(c)
        end
    end
end

## The key of the inference cache

# A hash of a type that is the same in every process: the `objectid` of a type is not, and a key made of them is only that of the session that made it, so that nothing that a workload infers when a package is compiled (see
# `src/precompile.jl`) could be used by the sessions that load it. `hash` of a `DataType` is made of its name and its parameters, and is the same; of a `Union` it does not tell unions apart (it is the same for all),
# so a union is its members, in order. (A type that a session makes, in a module that it makes, has a hash of its own: what is inferred for it is not found by another session, which can't have it.)
type_hash(@nospecialize(T)) = T isa Union ? hash(sort!(UInt[hash(t) for t in Base.uniontypes(T)])) : hash(T)

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

# the functions that the calls of unknown functions are made over (in the order that they were found: the union is made in it), and the callbacks
function closures_hash(cl::ClosureState)
    h = foldl((h, T) -> hash(type_hash(T), h), cl.functions; init = UInt(0))
    h = hash(length(cl.functions), h)
    h = foldl((h, (V, F)) -> hash(type_hash(F), hash(type_hash(V), h)), cl.callbacks; init = h)
    return hash(length(cl.callbacks), h)
end

"""
    inference_key(c::Compilation) -> Int

The number that the inference of this pass of the compilation is kept apart by (the parameters of the job: see `OverridesParams`): a hash of all that it is made with. Each state that inference reads is in it, by what it *is*,
and in a way that is the same in every process (`type_hash`).
"""
function inference_key(c::Compilation)
    h = hash(c.settings)
    h = hash(c.registered.version, h)
    h = hash(closures_hash(c.closures), h)
    h = hash(boxes_hash(c.boxes), h)
    h = hash(slots_hash(c.slots), h)
    return h % Int
end

"""
    begin_pass!(c::Compilation)

At the start of a pass: what the pass before found is forgotten (it was used, if it was to be), and the key is the one of what the pass is made with.
"""
function begin_pass!(c::Compilation)
    c.pass += 1
    cl = c.closures
    empty!(cl.seen_functions); empty!(cl.seen_functions_set); empty!(cl.seen_callbacks); empty!(cl.seen_cfunctions)
    cl.dispatch_requested = false; cl.union_used = false; cl.callback_call_requested = false; cl.box_function_seen = false; cl.optimized = 0; empty!(cl.optimized_unique)
    empty!(c.boxes.seen)
    s = c.slots
    empty!(s.universe_seen); empty!(s.stored_by_slot); empty!(s.raw_store_types); s.scan_truncated = false
    empty!(s.seen); empty!(s.seen_unknown); empty!(s.unknown_stores)
    c.dispatch.registered_used = false
    empty!(c.dispatch.unions)
    c.key = inference_key(c)
    return c
end
