# The objects that a program has as constants, and what the code reads of them (see "Slots of objects" in slots.jl).
#
# The slots of the program are by type: all of the `Observable{Any}` of a program are one slot, whose types are those that anything stores in any of them. Where the values of some of them are made of the values of others (Makie
# stores `(xscale[], yscale[])` in `transform_func[]`, all three `Observable{Any}`), the types of the slot are pairs of its own types, pairs of those, and so on: they grow with each pass, and the slot is given up. What
# each of them holds is not that (`xscale` holds `identity`). Here the objects that the program has as constants are known one by one, where the code reads them as constants:
#
# * An object is known where inference has it as a constant (`Const`), and what is read of a field of it is known (`fold_field_read`): of an immutable object, what the field has (inference does that itself, for the objects of
#   the code), and of a mutable one, what the field has if the program never writes that field. And a value of a type that the program never makes (no `new` of it), of which the constants have one object, is that object (a
#   closure that is a listener of an observable, which is called with itself as an argument of its type).
#
# What the facts are (found in each pass, and used in the next one, as the types of the slots are): the objects of each type that the constants have (`note_instance!`), the types that the program makes (`note_made!`), and the
# fields that it writes (`note_written!`).

function begin_objects_pass!(o::ObjectState)
    empty!(o.instances); empty!(o.made); o.made_any = false; empty!(o.written); o.written_any = false; o.wanted = false; o.folds = 0; empty!(o.scanned)
    empty!(o.stores); empty!(o.unattributed); empty!(o.unknown); empty!(o.recvstores); empty!(o.callsites)
    return o
end

# (a type whose objects are known one by one: a struct that is not a bits type, as those are values that the code makes by other means than `new`, `reinterpret` say, and a singleton is a constant to inference already)
tracked_object_type(@nospecialize(S)) = S isa DataType && isconcretetype(S) && isstructtype(S) && !isbitstype(S) && !(S <: Core.GenericMemory) && !(S <: Array) &&
                                         !(S <: Core.MethodInstance) && !(S <: Core.CodeInstance) && !(S <: Method) && !(S <: Core.TypeName) && !(S <: Module) && !(S <: Task)

# (each of these is kept with the method while its facts are recorded, and found again when they are replayed, as the stores in the slots are: a pass that takes a method from the cache does not look at its code again)
function note_instance!(c::Compilation, @nospecialize(x))
    S = typeof(x)
    tracked_object_type(S) || return
    sink = c.slots.facts_sink
    sink === nothing || (push!(sink, ((:instance, S, nothing), ObjRef(x))); return)
    o = c.objects
    r = get(o.instances, S, nothing)
    if r === nothing
        o.instances[S] = ObjRef(x)
    elseif r !== MANY_INSTANCES && r.x !== x
        o.instances[S] = MANY_INSTANCES
    end
    return
end

# (the objects of a constant, from what was found in it: once for each constant in a pass)
function note_instances_of!(c::Compilation, @nospecialize(x), facts)
    o = c.objects
    x in o.scanned && return
    push!(o.scanned, x)
    for (key, T) in facts
        key[1] === :instance && note_instance!(c, T.x)
    end
    return
end

function note_made!(c::Compilation, @nospecialize(S))
    (tracked_object_type(S) || !(S isa DataType && isconcretetype(S))) || return
    sink = c.slots.facts_sink
    sink === nothing ? push!(c.objects.made, S) : push!(sink, ((:made, S, nothing), Any))
    return
end

function note_made_any!(c::Compilation)
    sink = c.slots.facts_sink
    sink === nothing ? (c.objects.made_any = true) : push!(sink, ((:made, Any, nothing), Any))
    return
end

function note_written!(c::Compilation, @nospecialize(S), name)
    sink = c.slots.facts_sink
    sink === nothing || (push!(sink, ((:written, S, name), Any)); return)
    o = c.objects
    if S isa DataType && isconcretetype(S) && isstructtype(S)
        n = name isa Symbol ? name : name isa Integer && 1 <= name <= fieldcount(S) ? fieldname(S, name) : :*
        push!(o.written, (S, n isa Symbol ? n : :*))
    elseif name isa Symbol
        push!(o.written, (nothing, name))
    else
        o.written_any = true
    end
    return
end

# At the end of a pass: what it found is what the next one uses. Whether that is different from what this pass used (another pass is then made, as for the types of the slots)
function update_objects!(c::Compilation)
    o = c.objects
    o.made_any && push!(o.made, Any)
    o.written_any && push!(o.written, (nothing, :*))
    changed = !o.ready ? o.wanted : (o.instances != o.use_instances || o.made != o.use_made || o.written != o.use_written ||
                                     o.stores != o.use_stores || o.unattributed != o.use_unattributed || o.unknown != o.use_unknown)
    trace_on() && trace("objects: ", o.folds, " reads known; ", count(r -> r !== MANY_INSTANCES, values(o.instances)), " types with one object of ", length(o.instances), "; ", length(o.made), " types made; ",
                        length(o.written), " fields written", changed ? " (changed)" : "")
    if c.settings.why # (`STATIC_RUNTIME_SLOTS_WHY`: what is stored in the objects)
        describe(k) = k[1] isa ObjRef ? string(typeof(k[1].x), " @", string(objectid(k[1].x); base = 16)[1:6], ".", k[2]) : string(k[1], ".", k[2])
        println(stderr, "== objects: stores in ", length(o.stores), " fields of objects, ", length(o.unattributed), " of objects that are not known; unknown in ", length(o.unknown))
        for (k, T) in o.stores; println(stderr, "   in ", describe(k), " => ", first(string(T), 200)); end
        for (k, T) in o.unattributed; println(stderr, "   not known: ", describe(k), " => ", first(string(T), 200)); end
        for k in o.unknown; println(stderr, "   unknown: ", describe(k)); end
    end
    o.use_instances = copy(o.instances); o.use_made = copy(o.made); o.use_written = copy(o.written)
    o.use_stores = copy(o.stores); o.use_unattributed = copy(o.unattributed); o.use_unknown = copy(o.unknown)
    o.ready = true
    return changed
end

# The object that a value is, where it is known: a constant, or the one object of a type that the code never makes
function known_object(c::Compilation, @nospecialize(a))
    c.settings.objects || return nothing
    a isa Core.Const && return ObjRef(a.val)
    S = CC.widenconst(a)
    tracked_object_type(S) || return nothing
    o = c.objects
    o.ready || return nothing # (nothing is known before a pass has found the facts; a read that would be worth knowing says so, see `fold_field_read`)
    (S in o.use_made || Any in o.use_made) && return nothing
    r = get(o.use_instances, S, nothing)
    (r === nothing || r === MANY_INSTANCES) && return nothing
    return r
end

field_written(o::ObjectState, @nospecialize(S), name::Symbol) =
    (S, name) in o.use_written || (S, :*) in o.use_written || (nothing, name) in o.use_written || (nothing, :*) in o.use_written

# What is read of a field of an object that is known, if it is known: the value of the field, as a constant (`nothing` where it is not known)
function fold_field_read(c::Compilation, argtypes::Vector{Any})
    length(argtypes) == 3 || return nothing
    t = argtypes[3]
    (t isa Core.Const && (t.val isa Symbol || t.val isa Integer)) || return nothing
    o = c.objects
    if !o.ready
        # (another pass is made for the facts only where a read could be known and would tell inference something: a field of an abstract type of an object that may be known)
        c.settings.objects && worth_knowing(argtypes[2], t.val) && (o.wanted = true)
        return nothing
    end
    r = known_object(c, argtypes[2])
    r === nothing && return nothing
    x = r.x
    S = typeof(x)
    isstructtype(S) || return nothing
    i = t.val isa Symbol ? Base.fieldindex(S, t.val, false) : (1 <= t.val <= fieldcount(S) ? Int(t.val) : 0)
    i == 0 && return nothing
    isdefined(x, i) || return nothing
    ismutabletype(S) && field_written(o, S, fieldname(S, i)) && return nothing
    v = getfield(x, i)
    # (only what is worth knowing as a constant: an object, which is what the reads of its fields are known of, or what a field of an abstract type holds)
    (tracked_object_type(typeof(v)) || !isconcretetype(fieldtype(S, i))) || return nothing
    c.objects.folds += 1
    return Core.Const(v)
end

## Stores in objects
#
# What a field of an object holds, where the object is known (`object_field_type`): what it has when compiling, and what the code stores in it. A store is in an object where the code has the object as a constant
# (`setfield!(Const(o), ...)`), or in an object that a call gives to a method that stores in its argument (`setindex!(obs, v)` stores `v` in `obs.val`): the calls of the method say which object (`resolve_object_stores!`).
# A store in an object that is not known (the method is called with one that is not, or by a call that is not seen) is in any object of its type (`unattributed`), which is what each of them is then said to hold too.

# (a field of an object whose stores are kept by object: a field of an abstract type of a mutable struct)
object_slot(@nospecialize(S), name) = S isa DataType && ismutabletype(S) && tracked_object_type(S) && name isa Symbol && Base.fieldindex(S, name, false) != 0 && needs_slot_type(fieldtype(S, name))

function add_object_store!(c::Compilation, key, @nospecialize(T), table::Dict)
    o = c.objects
    T = stored_type(widen_tuple_type_values(T))
    T === Union{} && return
    if !closed_type(T)
        c.settings.why && !(key in o.unknown) && println(stderr, "   unknown store in ", key[1] isa ObjRef ? typeof(key[1].x) : key[1], ".", key[2], ": ", first(string(T), 150), "  in  ", context_text(c.slots.store_context))
        push!(o.unknown, key)
    else
        table[key] = Union{get(table, key, Union{}), T}
    end
    return
end

# (a fact of the objects: kept with the method while its facts are recorded, see `record_slot_facts!`, and applied when they are replayed)
function object_fact!(c::Compilation, kind::Symbol, a, b, @nospecialize(v))
    sink = c.slots.facts_sink
    sink === nothing ? apply_object_fact!(c, kind, a, b, v) : push!(sink, ((kind, a, b), v))
    return
end

function apply_object_fact!(c::Compilation, kind::Symbol, a, b, @nospecialize(v))
    o = c.objects
    if kind === :objstore
        add_object_store!(c, (a, b), v, o.stores)
    elseif kind === :unattributed
        add_object_store!(c, (a, b), v, o.unattributed)
    elseif kind === :recvstore
        push!(get!(Vector{Tuple{Symbol,Any}}, o.recvstores, a), (b, v))
    elseif kind === :callsite
        push!(get!(Vector{Tuple{Any,Vector{Any},Vector{Any}}}, o.callsites, a), v)
    end
    return
end

# A store of `T` (the value is the argument `val_arg` of the method, if it is one) in the field `name` of what the operand `recv` is (its type `S`, what inference has of it `lat`, and the argument of the method that it is,
# if it is one)
function note_object_store!(c::Compilation, @nospecialize(S), name, @nospecialize(lat), recv_arg, val_arg, @nospecialize(T))
    object_slot(S, name) || return
    s = c.slots
    if lat isa Core.Const
        # (an object that is a constant here: code that was inferred with it, see `const_prop_argument_heuristic`)
        object_fact!(c, :objstore, ObjRef(lat.val), name, T)
        return
    end
    if recv_arg !== nothing
        # (in the argument of a method: what its calls give it. Only in the facts that are recorded before the code is optimized, which are of the method for all of its calls; the optimized code has these in its calls)
        s.facts_sink === nothing || s.fact_mi === nothing || object_fact!(c, :recvstore, (s.fact_mi, recv_arg), name, val_arg !== nothing ? val_arg : T)
        return
    end
    r = lat === nothing ? nothing : known_object(c, lat)
    r === nothing ? object_fact!(c, :unattributed, S, name, T) : object_fact!(c, :objstore, r, name, T)
    return
end

# (whether an argument of a method can be an object whose stores are kept: a mutable struct with a field of an abstract type)
holds_object_slots(@nospecialize(P)) = P isa DataType && ismutabletype(P) && tracked_object_type(P) && any(i -> needs_slot_type(fieldtype(P, i)), 1:fieldcount(P))

# A call of `callee`, in the code of `mi` (before it is optimized), that gives it an object whose stores are kept: what each of its arguments is (see `callsites`)
# (whether a call of this signature gives a method an object whose stores are kept, asked once for each type in a compilation)
function gives_object(c::Compilation, sig::DataType)
    c.settings.objects || return false
    cache = c.objects.holds
    for n in 2:length(sig.parameters)
        P = sig.parameters[n]
        P isa Core.TypeofVararg && continue
        get!(() -> holds_object_slots(P), cache, P) && return true
    end
    return false
end

function note_object_call!(c::Compilation, ir::CC.IRCode, mi, callee::Core.MethodInstance, args::AbstractVector, sig::DataType)
    what = Vector{Any}(undef, length(args))
    types = Vector{Any}(undef, length(args))
    for n in eachindex(args)
        a = args[n]
        lat = CC.argextype(a, ir)
        k = argument_index(ir, a)
        what[n] = k !== nothing ? (mi, k) : known_object(c, lat)
        types[n] = value_type_of(lat)
    end
    object_fact!(c, :callsite, callee, nothing, (mi, what, types))
    return
end

param_type(mi, n::Int) = (sig = Base.unwrap_unionall(mi.specTypes); sig isa DataType && n <= length(sig.parameters) && !(sig.parameters[n] isa Core.TypeofVararg) ? sig.parameters[n] : Any)

# The stores in the arguments of methods, in the objects that the calls give them: from each method to its calls, and to theirs where they give it an argument of theirs. A method that is called by a call that is not seen (the
# code that reaches the method has it as a callee, `callers`, and no call of it was found there) stores in any object of the type.
function resolve_object_stores!(c::Compilation, callers::Dict{Any,Set{Any}})
    o = c.objects
    isempty(o.recvstores) && return
    work = Tuple{Any,Int,Symbol,Any}[]
    for ((mi, k), list) in o.recvstores, (name, v) in list
        push!(work, (mi, k, name, v))
    end
    done = Set{Any}()
    while !isempty(work)
        item = pop!(work)
        item in done && continue
        push!(done, item)
        mi, k, name, v = item
        sites = get(o.callsites, mi, ())
        seen = Set{Any}(site[1] for site in sites)
        S = param_type(mi, k)
        value_of(x) = x isa Int ? param_type(mi, x) : x
        if isempty(get(callers, mi, ())) || any(cm -> !(cm in seen), get(callers, mi, ()))
            apply_object_fact!(c, :unattributed, S, name, value_of(v))
        end
        for (cm, what, types) in sites
            k <= length(what) || continue
            # (the value: what the call gives as the argument `v` of the method, an argument of the caller or a type)
            val = v isa Int ? (v <= length(what) && what[v] isa Tuple ? what[v] : (v <= length(types) ? types[v] : Any)) : v
            r = what[k]
            if r isa ObjRef
                apply_object_fact!(c, :objstore, r, name, val isa Tuple ? param_type(val[1], val[2]) : val)
            elseif r isa Tuple
                push!(work, (r[1], r[2], name, val isa Tuple && val[1] === r[1] ? val[2] : (val isa Tuple ? param_type(val[1], val[2]) : val)))
            else
                apply_object_fact!(c, :unattributed, types[k], name, val isa Tuple ? param_type(val[1], val[2]) : val)
            end
        end
    end
    return
end

# What is read of a field of an object that is known and that the code writes: what it has when compiling, and what is stored in it (in it, and in an object of its type that is not known), or `nothing` where that is not known
function object_field_type(c::Compilation, argtypes::Vector{Any})
    o = c.objects
    o.ready || return nothing
    length(argtypes) == 3 || return nothing
    t = argtypes[3]
    (t isa Core.Const && t.val isa Symbol) || return nothing
    r = known_object(c, argtypes[2])
    r === nothing && return nothing
    x = r.x
    S = typeof(x)
    name = t.val
    object_slot(S, name) || return nothing
    ((r, name) in o.use_unknown || (S, name) in o.use_unknown) && return nothing
    T = isdefined(x, name) ? stored_value_type(getfield(x, name)) : Union{}
    T = Union{T, get(o.use_stores, (r, name), Union{}), get(o.use_unattributed, (S, name), Union{})}
    T === Union{} && return nothing
    (closed_type(T) && Base.unionlen(T) <= c.settings.slot_limit) || return nothing
    return T
end

# (the methods that a call may be, from what inference has of it)
function call_matches(@nospecialize(info))
    info isa CC.MethodMatchInfo && return info.results.matches
    info isa CC.UnionSplitInfo && return Core.MethodMatch[m for i in info.split for m in call_matches(i)]
    return Core.MethodMatch[]
end

# (what inference has of an operand of the optimized code: the type of a statement, a constant; `nothing` for an argument, whose stores are those of the method's calls)
# (the optimizer widens what inference had of a statement: a field of an object that is known is found again, as the read was, see `fold_field_read`)
function optimized_lattice(src::Core.CodeInfo, @nospecialize(x), depth::Int = 0)
    if x isa Core.SSAValue
        src.ssavaluetypes isa Vector || return nothing
        t = src.ssavaluetypes[x.id]
        t isa Core.Const && return t
        depth < 8 || return t
        st = src.code[x.id]
        st isa Expr && st.head === :(=) && length(st.args) == 2 && (st = st.args[2])
        if st isa Expr && st.head === :call && length(st.args) == 3 && called_function(src.code, st.args[1]) === Core.getfield
            recv = optimized_lattice(src, st.args[2], depth + 1)
            name = st.args[3] isa QuoteNode ? st.args[3].value : st.args[3]
            if recv !== nothing && (name isa Symbol || name isa Integer)
                folded = fold_field_read(compilation(), Any[Core.Const(Core.getfield), recv, Core.Const(name)])
                folded === nothing || return folded
            end
        elseif st isa Core.PiNode
            v = optimized_lattice(src, st.val, depth + 1)
            v isa Core.Const && return v
        end
        return t
    end
    x isa Core.Argument && return nothing
    (x isa Core.SlotNumber || x isa Expr) && return nothing
    v = constant_operand(x)
    return v === nothing ? nothing : Core.Const(v)
end

# A call that is given an object that is known, whose fields are kept by object (`holds_object_slots`), is inferred with it as a constant (Julia does not, for a mutable object: what it reads of it is not a constant), so
# that what the method reads of the object is what that object has (`to_value(obs)`, which reads `obs[]`, given one of the observables of an `onany`)
function CC.const_prop_argument_heuristic(interp::OverridesInterpreter, arginfo::CC.ArgInfo, sv::CC.AbsIntState)
    c = CURRENT_COMPILATION[]
    if c !== nothing && c.settings.objects && c.objects.ready && c.slots.mode === :on
        any(a -> a isa Core.Const && holds_object_slots(typeof(a.val)), arginfo.argtypes) && return true
    end
    return @invoke CC.const_prop_argument_heuristic(interp::CC.AbstractInterpreter, arginfo::CC.ArgInfo, sv::CC.AbsIntState)
end

# (whether a read of the field `name` of what `a` is could be known as one of an object, and tell inference something: a field of an abstract type, of an object that is a constant, or of a type that may have one object)
function worth_knowing(@nospecialize(a), name)
    S = a isa Core.Const ? typeof(a.val) : CC.widenconst(a)
    (tracked_object_type(S) && isstructtype(S)) || return false
    i = name isa Symbol ? Base.fieldindex(S, name, false) : (name isa Integer && 1 <= name <= fieldcount(S) ? Int(name) : 0)
    i == 0 && return false
    a isa Core.Const && !ismutabletype(S) && return false # (inference knows what an immutable constant holds)
    return needs_slot_type(fieldtype(S, i))
end
