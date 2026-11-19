# The objects that a program has as constants, and what the code reads of them (see "Slots of objects" in slots.jl).
#
# The slots of the program are by type: all of the `Observable{Any}` of a program are one slot, whose types are those that anything stores in any of them. Where the values of some of them are made of the values of others (Makie
# stores `(xscale[], yscale[])` in `transform_func[]`, all three `Observable{Any}`), the types of the slot are pairs of its own types, pairs of those, and so on: they grow with each pass, and the slot is given up. What
# each of them holds is not that (`xscale` holds `identity`). Here the objects that the program has as constants are known one by one, where the code reads them as constants:
#
# * An object is known where inference has it as a constant (`Const`), and what is read of a field of it is known (`fold_field_read`): of an immutable object, what the field has (inference does that itself, for the objects of
#   the code), and of a mutable one, what the field has if the program never writes that field.
# * A field of an abstract type of an object that is known holds what it has when compiling and what is stored in it (`object_field_type`, see "Stores in objects" below).
#
# The facts are found in each pass, and used in the next one, as the types of the slots are: the fields that the code writes (`note_written!`), and the stores in objects.

function begin_objects_pass!(o::ObjectState)
    empty!(o.written); o.written_any = false; o.wanted = false; o.folds = 0
    empty!(o.stores); empty!(o.unattributed); empty!(o.unknown); empty!(o.recvstores); empty!(o.callsites); empty!(o.invoked); empty!(o.direct)
    return o
end

# (a type whose objects are known one by one: a struct that is not a bits type, as those are values that the code makes by other means than `new`, `reinterpret` say, and a singleton is a constant to inference already)
tracked_object_type(@nospecialize(S)) = S isa DataType && isconcretetype(S) && isstructtype(S) && !isbitstype(S) && !(S <: Core.GenericMemory) && !(S <: Array) &&
                                         !(S <: Core.MethodInstance) && !(S <: Core.CodeInstance) && !(S <: Method) && !(S <: Core.TypeName) && !(S <: Module) && !(S <: Task)

# (kept with the method while its facts are recorded, and found again when they are replayed, as the stores in the slots are: a pass that takes a method from the cache does not look at its code again)
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
    o.written_any && push!(o.written, (nothing, :*))
    changed = !o.ready ? o.wanted : (o.written != o.use_written ||
                                     o.stores != o.use_stores || o.unattributed != o.use_unattributed || o.unknown != o.use_unknown)
    trace_on() && trace("objects: ", o.folds, " reads known; ", length(o.written), " fields written; stores in ", length(o.stores), " fields of objects", changed ? " (changed)" : "")
    if c.settings.why # (`STATIC_RUNTIME_SLOTS_WHY`: what is stored in the objects)
        describe(k) = k[1] isa ObjRef ? string(typeof(k[1].x), " @", string(objectid(k[1].x); base = 16)[1:6], ".", k[2]) : string(k[1], ".", k[2])
        println(stderr, "== objects: stores in ", length(o.stores), " fields of objects, ", length(o.unattributed), " of objects that are not known; unknown in ", length(o.unknown))
        for (k, T) in o.stores; println(stderr, "   in ", describe(k), " => ", first(string(T), 200)); end
        for (k, T) in o.unattributed; println(stderr, "   not known: ", describe(k), " => ", first(string(T), 200)); end
        for k in o.unknown; println(stderr, "   unknown: ", describe(k)); end
    end
    o.use_written = copy(o.written)
    o.use_stores = copy(o.stores); o.use_unattributed = copy(o.unattributed); o.use_unknown = copy(o.unknown)
    o.ready = true
    return changed
end

# The object that a value is, where it is known: a constant. (A type that the constants have one object of, and that the code does not `new`, is not taken to be that object: constants are in a program in ways that the
# code that is looked at does not show, a call that inference ran when compiling with one as its argument (`textwidth(styled"...")`, whose `AnnotatedString` is then in no statement), and the read of a field of the
# type in a method for all of its objects would be that of the one that is seen: what that method gives would be wrong for the others.)
function known_object(c::Compilation, @nospecialize(a))
    c.settings.objects || return nothing
    a isa Core.Const && return ObjRef(a.val)
    return nothing
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
        # (another pass is made for the facts only where a read could be known and would tell inference something: a field of an abstract type of a mutable object that is a constant)
        c.settings.objects && worth_knowing(argtypes[2], t.val) && (o.wanted = true; o.consulted = true)
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
    v = getfield(x, i)
    # (only what is worth knowing as a constant: an object, which is what the reads of its fields are known of, or what a field of an abstract type holds)
    (tracked_object_type(typeof(v)) || !isconcretetype(fieldtype(S, i))) || return nothing
    if ismutabletype(S)
        o.consulted = true # (what is read depends on what the code writes: see `objects_hash`)
        field_written(o, S, fieldname(S, i)) && return nothing
    end
    c.objects.folds += 1
    c.settings.why && println(stderr, "   folded ", argtypes[2] isa Core.Const ? "constant " : "only object of ", S, ".", fieldname(S, i), " => ", first(repr(v), 120))
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
    c.settings.why && table === o.unattributed && !haskey(table, key) && println(stderr, "   not known store in ", key[1], ".", key[2], ": ", first(string(T), 100), "  in  ", context_text(c.slots.store_context))
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
    # (a store of a method, that is replayed: of the program only if the code of the method is, which is known when all are replayed, see `resolve_object_stores!`)
    if (kind === :objstore || kind === :unattributed) && o.replaying !== nothing
        push!(get!(Vector{Tuple{Symbol,Any,Any,Any}}, o.direct, o.replaying), (kind, a, b, v))
        return
    end
    if kind === :objstore
        add_object_store!(c, (a, b), v, o.stores)
    elseif kind === :unattributed
        add_object_store!(c, (a, b), v, o.unattributed)
    elseif kind === :recvstore
        push!(get!(Vector{Tuple{Any,Symbol,Any}}, o.recvstores, a), (b[1], b[2], v))
    elseif kind === :callsite
        push!(get!(Vector{Tuple{Any,Vector{Any},Vector{Any}}}, o.callsites, a), v)
    elseif kind === :invoked
        push!(o.invoked, a)
    end
    return
end

# A store of `T` (the value is the argument `val_arg` of the method, if it is one) in the field `name` of what the operand `recv` is (its type `S`, what inference has of it `lat`, and where it is read from an argument of the
# method, if it is: `(n, path)`, the fields of the argument `n` that it is read through, as `p.out` of a listener `p`)
function note_object_store!(c::Compilation, @nospecialize(S), name, @nospecialize(lat), recv_arg, val_arg, @nospecialize(T))
    c.objects.recording || return # (only from the code after it is inlined, see `record_object_facts!`)
    object_slot(S, name) || return
    s = c.slots
    if lat isa Core.Const
        # (an object that is a constant here: code that was inferred with it, see `maybe_get_const_prop_profitable`)
        object_fact!(c, :objstore, ObjRef(lat.val), name, T)
        return
    end
    if recv_arg !== nothing
        # (in the argument of a method: what its calls give it. Only in the facts that are recorded before the code is optimized, which are of the method for all of its calls; the optimized code has these in its calls)
        s.facts_sink === nothing || s.fact_mi === nothing || object_fact!(c, :recvstore, (s.fact_mi, recv_arg[1]), (recv_arg[2], name), val_arg !== nothing ? val_arg : T)
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
    for n in 1:length(sig.parameters) # (the function too: a listener, whose fields are the objects that it stores in)
        P = sig.parameters[n]
        P isa Core.TypeofVararg && continue
        get!(() -> leads_to_slots_type(P), cache, P) && return true
    end
    return false
end

# (whether a value of the type `P` is, or holds in its fields as they are declared, an object whose fields are kept by object: a mutable struct with a field of an abstract type, or an immutable struct of such)
leads_to_slots_type(@nospecialize(P), depth::Int = 0) = holds_object_slots(P) ||
    (depth < 2 && P isa DataType && isconcretetype(P) && isstructtype(P) && !ismutabletype(P) && tracked_object_type(P) && any(i -> leads_to_slots_type(fieldtype(P, i), depth + 1), 1:fieldcount(P)))

function note_object_call!(c::Compilation, ir::CC.IRCode, mi, callee::Core.MethodInstance, args::AbstractVector, sig::DataType)
    c.objects.recording || return
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
function resolve_object_stores!(c::Compilation, rootmi)
    o = c.objects
    # (the code of a method is of the program if a call that is left in the code calls it, or it is where the program, or a `@cfunction` of it, starts: a method that is only inlined is in its callers)
    cfunctions = Any[r.ftype for r in c.closures.cfunction_roots]
    entered(mi) = mi === rootmi || (sig = Base.unwrap_unionall(mi.specTypes); sig isa DataType && !isempty(sig.parameters) && any(F -> sig.parameters[1] === F, cfunctions))
    # (any call that is left: one that gives the method no object, as `run_finalizer(Val(id), F, T, addr)` that runs a finalizer, whose code is inlined in it, is not in `callsites`)
    runs(mi) = entered(mi) || mi in o.invoked || !isempty(get(o.callsites, mi, ()))
    for (mi, list) in o.direct
        runs(mi) || continue
        for (kind, a, b, v) in list
            apply_object_fact!(c, kind, a, b, v)
        end
    end
    work = Tuple{Any,Int,Any,Symbol,Any}[]
    for ((mi, k), list) in o.recvstores, (path, name, v) in list
        push!(work, (mi, k, path, name, v))
    end
    done = Set{Any}()
    while !isempty(work)
        item = pop!(work)
        item in done && continue
        push!(done, item)
        mi, k, path, name, v = item
        runs(mi) || continue
        value_of(x) = x isa Int ? param_type(mi, x) : x
        if entered(mi) # (its arguments are given by what calls the program)
            c.settings.why && (c.slots.store_context = ("the arguments of where the program starts", mi))
            apply_object_fact!(c, :unattributed, path_type(param_type(mi, k), path), name, value_of(v))
        end
        for (cm, what, types) in get(o.callsites, mi, ())
            k <= length(what) || continue
            # (the value: what the call gives as the argument `v` of the method, an argument of the caller or a type)
            val = v isa Int ? (v <= length(what) && what[v] isa Tuple ? what[v] : (v <= length(types) ? types[v] : Any)) : v
            valtype = val isa Tuple ? param_type(val[1], val[2]) : val
            r = what[k]
            if r isa ObjRef
                target = follow_fields(c, r.x, path)
                target === nothing ? apply_object_fact!(c, :unattributed, path_type(typeof(r.x), path), name, valtype) :
                                     apply_object_fact!(c, :objstore, ObjRef(target), name, valtype)
            elseif r isa Tuple
                push!(work, (r[1], r[2], path, name, val isa Tuple && val[1] === r[1] ? val[2] : valtype))
            else
                apply_object_fact!(c, :unattributed, path_type(types[k], path), name, valtype)
            end
        end
    end
    return
end

# (the object that the fields `path` of `x` lead to, where those are fields that do not change, or `nothing`)
function follow_fields(c::Compilation, @nospecialize(x), path)
    for name in path
        T = typeof(x)
        (isstructtype(T) && Base.fieldindex(T, name, false) != 0 && isdefined(x, name)) || return nothing
        ismutabletype(T) && field_written(c.objects, T, name) && return nothing
        x = getfield(x, name)
    end
    return x
end

# (the type of what the fields `path` of a value of the type `T` are, as declared)
function path_type(@nospecialize(T), path)
    for name in path
        (T isa DataType && isstructtype(T) && Base.fieldindex(T, name, false) != 0) || return Any
        T = fieldtype(T, name)
    end
    return T
end

# (where an operand of the code before it is optimized is read from an argument of the method through fields with names that are constants: `(n, path)`, or `nothing`)
function receiver_path(ir::CC.IRCode, @nospecialize(x))
    path = Symbol[]
    for _ in 1:8
        x isa Core.Argument && return (x.n, Tuple(reverse!(path)))
        (x isa Core.SSAValue && x.id <= length(ir.stmts)) || return nothing
        st = ir.stmts[x.id][:stmt]
        if st isa Core.PiNode
            x = st.val
        elseif st isa Expr && st.head === :call && length(st.args) == 3 &&
               ((f = CC.singleton_type(CC.argextype(st.args[1], ir))) === Core.getfield || (f === Base.getproperty && default_getproperty(CC.widenconst(CC.argextype(st.args[2], ir)))))
            name = st.args[3] isa QuoteNode ? st.args[3].value : st.args[3]
            name isa Symbol || return nothing
            push!(path, name)
            x = st.args[2]
        else
            k = argument_index(ir, x)
            return k === nothing ? nothing : (k, Tuple(reverse!(path)))
        end
    end
    return nothing
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
    o.consulted = true
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

# A call that is given an object that is known, whose fields are kept by object (`holds_object_slots`), or an immutable one that holds such objects (a listener, a tuple of observables), is inferred with it as a constant:
# Julia does not, for a mutable object (what it reads of it is not a constant), nor for a call whose result can not be more precise (`(listener::Pair)()` gives `nothing`), and what the method reads of the objects would
# then be what all of the objects of their type hold (`to_value(obs)`, which reads `obs[]`, given one of the observables of an `onany`)
function CC.maybe_get_const_prop_profitable(interp::OverridesInterpreter, result::CC.MethodCallResult, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                            match::Core.MethodMatch, sv::CC.AbsIntState)
    c = CURRENT_COMPILATION[]
    if c !== nothing && c.settings.objects && c.objects.ready && c.slots.mode === :on && !result.edgecycle &&
       any(a -> a isa Core.Const && leads_to_object_slots(c, a.val), arginfo.argtypes)
        mi = CC.specialize_method(match; preexisting = false)
        mi isa Core.MethodInstance && return mi
    end
    return @invoke CC.maybe_get_const_prop_profitable(interp::CC.AbstractInterpreter, result::CC.MethodCallResult, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                                      match::Core.MethodMatch, sv::CC.AbsIntState)
end

# (whether an object is, or holds in a field or the element of a tuple, an object whose fields are kept by object)
function leads_to_object_slots(c::Compilation, @nospecialize(x), depth::Int = 0)
    T = typeof(x)
    holds_object_slots(T) && return true
    (depth < 2 && isstructtype(T) && !ismutabletype(T) && tracked_object_type(T)) || return false
    for i in 1:fieldcount(T)
        isdefined(x, i) && leads_to_object_slots(c, getfield(x, i), depth + 1) && return true
    end
    return false
end

# (whether a read of the field `name` of what `a` is could be known as one of an object, and tell inference something: a field of an abstract type of a mutable object that is a constant)
function worth_knowing(@nospecialize(a), name)
    a isa Core.Const || return false
    S = typeof(a.val)
    (tracked_object_type(S) && ismutabletype(S)) || return false # (inference knows what an immutable constant holds)
    i = name isa Symbol ? Base.fieldindex(S, name, false) : (name isa Integer && 1 <= name <= fieldcount(S) ? Int(name) : 0)
    i == 0 && return false
    return needs_slot_type(fieldtype(S, i))
end


# (whether `getproperty` of a value of the type `T` is Base's, which is `getfield`: `p.out` before it is inlined)
function default_getproperty(@nospecialize(T))
    (T isa DataType && isconcretetype(T)) || return false
    m = try which(Base.getproperty, Tuple{T,Symbol}) catch; return false end
    return m.module === Base && m.sig == Tuple{typeof(Base.getproperty),Any,Symbol}
end

# The facts of the objects of a method, from its code after the callees that it inlines are in it (`ssa_inlining_pass!`): the stores in objects, where what is inlined has the objects that the method gives it as constants
# (`listener.out.val = (listener.a.val, ...)` of a listener that is a constant), and the calls that are left (`:invoke`), which are the calls of the program. They are added to the facts that are kept with the method.
function record_object_facts!(c::Compilation, ir::CC.IRCode, mi::Core.MethodInstance)
    o = c.objects
    (o.pending_facts === nothing || o.pending_mi !== mi) && return
    s = c.slots
    s.facts_sink = o.pending_facts
    s.fact_mi = mi
    o.recording = true
    seen = Set{Any}()
    try
        for pc in 1:length(ir.stmts)
            st = ir.stmts[pc][:stmt]
            st isa Expr || continue
            c.settings.why && (s.store_context = (mi, pc, st, nothing))
            learn_object_store!(c, ir, st)
            # (a call that is left as a call, of a builtin (`Core._apply_iterate` of a splat of a tuple of a union) or one that is dispatched: the methods that it may reach run too, with what is inlined in them)
            if st.head === :call
                for callee in reached_instances(ir.stmts[pc][:info])
                    callee in seen || (push!(seen, callee); object_fact!(c, :invoked, callee, nothing, nothing))
                end
            end
            if st.head === :invoke
                target = st.args[1]
                callee = target isa Core.CodeInstance ? target.def : target
                callee isa Core.MethodInstance || continue
                callee in seen || (push!(seen, callee); object_fact!(c, :invoked, callee, nothing, nothing))
                sig = Base.unwrap_unionall(callee.specTypes)
                (sig isa DataType && length(st.args) - 1 == length(sig.parameters) && gives_object(c, sig)) || continue
                note_object_call!(c, ir, mi, callee, view(st.args, 2:length(st.args)), sig)
            end
        end
    finally
        o.recording = false
        s.facts_sink = nothing
        s.fact_mi = nothing
        o.pending_facts = nothing
        o.pending_mi = nothing
    end
    return
end

# (the method instances that a call may reach, from what inference found of it)
function reached_instances(@nospecialize(info), out::Vector{Any} = Any[])
    if info isa CC.MethodMatchInfo
        for (i, m) in enumerate(info.results.matches)
            e = i <= length(info.edges) ? info.edges[i] : nothing
            mi = e isa Core.CodeInstance ? e.def : CC.specialize_method(m; preexisting = true)
            mi isa Core.MethodInstance && push!(out, mi)
        end
    elseif info isa CC.UnionSplitInfo
        for i in info.split; reached_instances(i, out); end
    elseif info isa CC.ApplyCallInfo
        reached_instances(info.call, out)
    elseif info isa CC.UnionSplitApplyCallInfo
        for i in info.infos; reached_instances(i, out); end
    elseif info isa CC.InvokeCallInfo || info isa CC.OpaqueClosureCallInfo
        mi = info.edge isa Core.CodeInstance ? info.edge.def : CC.specialize_method(info.match; preexisting = true)
        mi isa Core.MethodInstance && push!(out, mi)
    end
    return out
end

# (a store in a field of a struct, `setfield!` or a call of `setproperty!` that is left, with what the receiver and the value are)
function learn_object_store!(c::Compilation, ir::CC.IRCode, st::Expr)
    if st.head === :invoke
        length(st.args) == 5 || return
        f = CC.singleton_type(CC.argextype(st.args[2], ir))
        f === Base.setproperty! || return
        recv, name, v = st.args[3], st.args[4], st.args[5]
    elseif st.head === :call && length(st.args) >= 4
        f = CC.singleton_type(CC.argextype(st.args[1], ir))
        (f === Core.setfield! || f === Base.setproperty!) || return
        recv, name, v = st.args[2], st.args[3], st.args[4]
    else
        return
    end
    name = name isa QuoteNode ? name.value : name
    name isa Symbol || return
    S = CC.widenconst(CC.argextype(recv, ir))
    note_object_store!(c, S, name, CC.argextype(recv, ir), receiver_path(ir, recv), argument_index(ir, v), value_type_of(CC.argextype(v, ir)))
    return
end

## Code for each object
##
## An object that is a constant is known in the code that has it, and in what that code calls with it only where Julia propagates the constant into the call, which it does not do for a method that is already being inferred
## with another constant higher up (`is_constprop_edge_recursed`: the updates of observables are such chains, `setindex!` -> `notify` -> a listener -> `setindex!` of another observable -> `notify`), and what it propagates is only
## used where the call is inlined. What a package says (`keyed_method(f, x)`, a method of an extension) is made code for the object itself: the call `f(x, args...)` with `x` a constant is the call `g(key, args...)`, where
## the key is a type of its own for each object (`ObjectKey{N}`), so that `g` is compiled for each object, and has it (`object_for(key)`) as a constant. Recursion over the keys is as finite as the objects.
## (The numbers are the compilation's own: with the cache that compilations share, `STATIC_RUNTIME_CACHE=1`, there are no keys.)

"""
    StaticRuntime.ObjectKey{N}

The key of an object that is a constant of the code that is compiled (see `keyed_method`): `object_for(key)` is the object, in the code that is compiled for the key.
"""
struct ObjectKey{N} end


"""
    StaticRuntime.keyed_method(f, x)

For extensions: the function `g` that the call `f(x, args...)` is made, `g(key, args...)`, where `x` is an object that is a constant when compiling and `key` is its `ObjectKey`; or `nothing` (the default). `g` gets the object
with `object_for(key)`. (The calls that are looked at are those of `setindex!` and `notify`.)
"""
keyed_method(@nospecialize(f), @nospecialize(x)) = nothing

"""
    StaticRuntime.object_for(key::ObjectKey)

The object of the key, as a constant, in code that is compiled.
"""
function object_for(::ObjectKey{N}) where {N}
    # (while compiling, as inference has it; there is no key otherwise)
    c = CURRENT_COMPILATION[]
    (c !== nothing && N isa Int && 1 <= N <= length(c.objects.keyed_objects)) || error("object_for: an object key is only known in compiled code")
    return c.objects.keyed_objects[N]
end

"""
    StaticRuntime.known_object_keys(f, x)

The keys of the objects of the tuple `f(x)`, made when compiling where `x` is a constant there (or a type), and `nothing` where it is not (and when the code is not compiled). It is what `x` has when compiling, which the
program may change: for what the code checks (the listeners of an observable, which are compared with what it calls).
"""
known_object_keys(@nospecialize(f), @nospecialize(x)) = nothing # (in inference, the method is not run: see below)

keyless(@nospecialize(x)) = isbits(x) && sizeof(x) > 0
keys_on(c::Compilation) = c.settings.objects && !c.settings.share_cache

function object_key!(c::Compilation, @nospecialize(x))
    o = c.objects
    n = get!(o.key_index, x) do
        push!(o.keyed_objects, x)
        length(o.keyed_objects)
    end
    return ObjectKey{n}()
end

function keyed_call(interp::OverridesInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv::CC.AbsIntState)
    argtypes = arginfo.argtypes
    (length(argtypes) >= 2 && argtypes[2] isa Core.Const) || return nothing
    c = CURRENT_COMPILATION[]
    (c !== nothing && keys_on(c)) || return nothing
    x = argtypes[2].val
    g = try Base.invokelatest(keyed_method, f, x) catch; nothing end
    g === nothing && return nothing
    push!(c.objects.keyed_functions, g)
    return CC.abstract_call(interp, CC.ArgInfo(nothing, Any[CC.Const(g), CC.Const(object_key!(c, x)), argtypes[3:end]...]), si, vtypes, sv)
end

for F in (typeof(Base.setindex!), typeof(Base.notify))
    @eval function CC.abstract_call_known(interp::OverridesInterpreter, f::$F, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
        call = keyed_call(interp, f, arginfo, si, vtypes, sv)
        call === nothing || return call
        return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                              vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
    end
end

# (not `:consistent`: what the call gives is of the compilation, and Julia is not to run the method itself for it, as it does for one that is, with constant arguments: `map(key_value, keys)`. Not `:inaccessiblememonly`:
# the object is memory that the program shares, and a store in it is an effect, which is not to be removed with a call whose result is not used, as a listener's)
const_call(@nospecialize(v)) = CC.Future(CC.CallMeta(CC.Const(v), Union{}, CC.Effects(CC.EFFECTS_TOTAL; consistent = CC.ALWAYS_FALSE, inaccessiblememonly = CC.ALWAYS_FALSE), CC.NoCallInfo()))

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(object_for), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 2
        K = CC.widenconst(argtypes[2])
        c = CURRENT_COMPILATION[]
        if c !== nothing && K isa DataType && K <: ObjectKey && isconcretetype(K)
            n = K.parameters[1]
            n isa Int && 1 <= n <= length(c.objects.keyed_objects) && return const_call(c.objects.keyed_objects[n])
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(known_object_keys), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    c = CURRENT_COMPILATION[]
    if c !== nothing && keys_on(c) && length(argtypes) == 3 && argtypes[3] isa Core.Const && (g = CC.singleton_type(argtypes[2])) !== nothing
        t = try Base.invokelatest(g, argtypes[3].val) catch; nothing end
        # (a value of bits that has a size has no key: it is not an object of the program that code refers to, but a value, which the code would have as one of this process. Then there are none, and the code does without)
        t isa Tuple && !any(keyless, t) && return const_call(map(x -> object_key!(c, x), t))
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# (in the code before it is optimized: what replaces the call, if it is one of those above, or `nothing`)
function keyed_replacement(c::Compilation, @nospecialize(called), call::Expr, @nospecialize(info), @nospecialize(t))
    if called === object_for || called === known_object_keys
        return t isa CC.Const ? QuoteNode(t.val) : nothing
    end
    (called === Base.setindex! || called === Base.notify) || return nothing
    isempty(c.objects.keyed_functions) && return nothing
    # (the methods of the call: one, or those of a split over the types of the value, `obs[] = cond ? a : b`, which are all of the same function and key)
    matches = info isa CC.MethodMatchInfo ? info.results.matches :
              info isa CC.UnionSplitInfo ? [m for i in info.split for m in i.results.matches] : nothing
    (matches === nothing || isempty(matches)) && return nothing
    keyed(m) = (sig = Base.unwrap_unionall(m.spec_types); sig isa DataType && length(sig.parameters) >= 2 && Base.issingletontype(sig.parameters[1]) && sig.parameters[1].instance in c.objects.keyed_functions &&
                (K = sig.parameters[2]; K isa DataType && K <: ObjectKey && isconcretetype(K)) ? (sig.parameters[1], sig.parameters[2]) : nothing)
    gks = map(keyed, matches)
    all(isnothing, gks) && return nothing
    # (a call that inference made of the keyed function is to be that call: what is inlined for it is its code, and the call of `f` that was left would be a call that never matches it)
    (any(isnothing, gks) || !allequal(gks)) && error("a call that is made for an object (see \"Code for each object\" in objects.jl) could not be replaced: ", call)
    G, K = gks[1]
    return Expr(:call, G.instance, K.instance, call.args[3:end]...)
end

# (whether the signature of a call has a key in it: one of a method that is compiled for an object, see above, whose recursion is not limited)
is_key_type(@nospecialize(p)) = p isa DataType && p <: ObjectKey
has_object_key(@nospecialize(sig)) = sig isa DataType && any(p -> is_key_type(p) || (p isa DataType && p <: Tuple && !(p <: Tuple{}) && any(is_key_type, p.parameters)), sig.parameters)
