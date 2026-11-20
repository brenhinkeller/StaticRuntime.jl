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

# The elements of a `Memory` are written (by `memoryrefset!` and the others, of a reference into it, or by a function of C that is given it): a fact of its type, `(M, :elements)`, as the fields of a struct are.
function note_memory_written!(c::Compilation, @nospecialize(t))
    T = CC.widenconst(t)
    T isa DataType || return
    if T <: Core.GenericMemoryRef && length(T.parameters) == 3
        T = Core.GenericMemory{T.parameters...}
    end
    T isa DataType && T <: Core.GenericMemory && isconcretetype(T) && note_written!(c, T, :elements)
    return
end

# At the end of a pass: what it found is what the next one uses. Whether that is different from what this pass used (another pass is then made, as for the types of the slots)
function update_objects!(c::Compilation)
    o = c.objects
    o.written_any && push!(o.written, (nothing, :*))
    # (another pass only where an answer to what inference asked is different with what this pass found: a fact that nothing asked about changes nothing that is inferred)
    o.once_wanted |= o.wanted
    changed = !o.ready ? o.wanted :
              (any(((S, name),) -> written_in(o.written, S, name) != written_in(o.use_written, S, name), o.asked_written) ||
               any(((r, name),) -> field_answer(o.stores, o.unattributed, o.unknown, r, name) != field_answer(o.use_stores, o.use_unattributed, o.use_unknown, r, name), o.asked_fields))
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

# (whether a field is written, by the facts `written`)
written_in(written, @nospecialize(S), name::Symbol) = (S, name) in written || (S, :*) in written || (nothing, name) in written || (nothing, :*) in written

# (the same, by the facts that this pass uses, asked by inference in the frame `sv`: the answer is part of what it infers with, see `objects_hash` and `depends!`)
function field_written(c::Compilation, @nospecialize(sv), @nospecialize(S), name::Symbol)
    o = c.objects
    push!(o.asked_written, (S, name))
    depends!(c, sv, (:written, S, name))
    return written_in(o.use_written, S, name)
end

# (what is stored in a field of an object, by the facts: `nothing` where something of a type that is not known is, or the union of what is stored in it and in the objects of its type that are not known)
function field_answer(stores, unattributed, unknown, r::ObjRef, name::Symbol)
    S = typeof(r.x)
    ((r, name) in unknown || (S, name) in unknown) && return nothing
    return Union{get(stores, (r, name), Union{}), get(unattributed, (S, name), Union{})}
end

# What is read of a field of an object that is known, if it is known: the value of the field, as a constant (`nothing` where it is not known). `sv` is the frame of inference that reads it (`nothing`: not inference)
function fold_field_read(c::Compilation, argtypes::Vector{Any}, @nospecialize(sv) = nothing)
    length(argtypes) == 3 || return nothing
    t = argtypes[3]
    (t isa Core.Const && (t.val isa Symbol || t.val isa Integer)) || return nothing
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
    o = c.objects
    depends!(c, sv, (:objready,)) # (what is read is known once the facts are there: see reuse.jl)
    if !o.ready
        # (another pass is made for the facts only where a read could be known and would tell inference something: a field of an abstract type of a mutable object that is a constant)
        worth_knowing(argtypes[2], t.val) && (o.wanted = true)
        return nothing
    end
    ismutabletype(S) && field_written(c, sv, S, fieldname(S, i)) && return nothing # (what is read depends on what the code writes: see `objects_hash`)
    o.folds += 1
    c.settings.why && println(stderr, "   folded ", argtypes[2] isa Core.Const ? "constant " : "only object of ", S, ".", fieldname(S, i), " => ", first(repr(v), 120))
    return Core.Const(v)
end

## Containers that the program does not change
#
# A lookup in a container that is a constant, with a key that is a constant (`graph.outputs[:positions]`, a `Dict` of the nodes of a graph), is what the container has when compiling where the program never changes a
# container of its type: the value, as a constant, which what the code does with it is then inferred for (the reads of its fields, the calls on it). The lookup itself is made by the program (it gives the same object).
# What changes a container: for a `Dict`, a write of a field of its type (every change of the keys or the values writes `age` or `count`, or more), or of the elements of the memory of its values (`map!` over its values
# writes them, and no field); for a `Vector`, a write of its `ref` or `size`, or of the elements of its memory (only of elements that are not bits: those are copied by `memmove` with pointers that are not typed, which the
# facts do not see). The facts are those of the pass before, as for the fields of objects (`fold_field_read`).
#
# What is not seen: a write through a pointer (`unsafe_store!`, a function of C that is given an address). What is known of an object is what its fields that hold references hold (an object, or a value of a field of an
# abstract type), and of a container the references in it; a reference is not written through a pointer (that is not seen by the collector: Julia has no write barrier there, and the types of the slots assume the same).
# The address of the elements of a `Memory` is a write of them all the same (`note_memory_written!` of `getfield(m, :ptr)`), as Julia's own copies of references are made through it.
function container_frozen(c::Compilation, @nospecialize(sv), @nospecialize(x))
    if x isa Dict
        D = typeof(x)
        for n in fieldnames(D)
            field_written(c, sv, D, n) && return false
        end
        return !field_written(c, sv, typeof(getfield(x, :vals)), :elements)
    elseif x isa Vector
        isbitstype(eltype(x)) && return false
        V = typeof(x)
        (field_written(c, sv, V, :ref) || field_written(c, sv, V, :size)) && return false
        return !field_written(c, sv, typeof(getfield(x, :ref).mem), :elements)
    end
    return false
end

# What `f(container, key)` gives (`getindex`, `get` with a default), where the container is a constant that the program does not change and the key is a constant: as a constant, or `nothing`
function fold_container_read(c::Compilation, @nospecialize(f), argtypes::Vector{Any}, @nospecialize(sv))
    c.settings.objects || return nothing
    n = length(argtypes)
    (n == 3 || (n == 4 && f === Base.get)) || return nothing
    d, k = argtypes[2], argtypes[3]
    (d isa Core.Const && k isa Core.Const && (d.val isa Dict || (d.val isa Vector && f === Base.getindex))) || return nothing
    x, key = d.val, k.val
    # (what the lookup gives now, and whether it is worth knowing as a constant: an object, which is what the reads of its fields are known of, or a value of a container of an abstract type.
    # A key that is not there gives the default, or a `KeyError`, which the call gives itself)
    if x isa Dict
        haskey(x, key) || return nothing
        v = x[key]
        ET = valtype(x)
    else
        (key isa Int && checkbounds(Bool, x, key) && isassigned(x, key)) || return nothing
        v = x[key]
        ET = eltype(x)
    end
    (tracked_object_type(typeof(v)) || !isconcretetype(ET)) || return nothing
    o = c.objects
    depends!(c, sv, (:objready,)) # (see reuse.jl)
    if !o.ready
        o.wanted = true # (another pass, with the facts of this one)
        return nothing
    end
    container_frozen(c, sv, x) || return nothing
    o.folds += 1
    c.settings.why && println(stderr, "   folded ", typeof(x), "[", repr(key), "] => ", first(repr(v), 120))
    return Core.Const(v)
end

for F in (typeof(Base.getindex), typeof(Base.get))
    @eval function CC.abstract_call_known(interp::OverridesInterpreter, f::$F, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
        call = @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                              vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
        (sv isa CC.InferenceState || CC.isready(call)) || return call
        folded = fold_container_read(compilation(), f, arginfo.argtypes, sv)
        return folded === nothing ? call : after_call(result_of_type, call, interp, sv, folded)
    end
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
function holds_object_slots(@nospecialize(P))
    (P isa DataType && ismutabletype(P) && tracked_object_type(P)) || return false
    for i in 1:fieldcount(P) # (a loop: see `meets_any`)
        needs_slot_type(fieldtype(P, i)) && return true
    end
    return false
end

# A call of `callee`, in the code of `mi` (before it is optimized), that gives it an object whose stores are kept: what each of its arguments is (see `callsites`)
# (whether a call of this signature gives a method an object whose stores are kept, asked once for each type in a compilation)
function gives_object(c::Compilation, sig::DataType)
    c.settings.objects || return false
    o = c.objects
    g = get(o.gives, sig, nothing) # (once for each signature: a method is called with the same one from many places)
    g === nothing || return g::Bool
    found = false
    for n in 1:length(sig.parameters) # (the function too: a listener, whose fields are the objects that it stores in)
        P = sig.parameters[n]
        P isa Core.TypeofVararg && continue
        # (not `get!` with a closure that has the type: a closure of each type is a method that Julia compiles, for each type that is asked about)
        h = get(o.holds, P, nothing)
        h === nothing && (h = o.holds[P] = leads_to_slots_type(P))
        h::Bool && (found = true; break)
    end
    o.gives[sig] = found
    return found
end

# (whether a value of the type `P` is, or holds in its fields as they are declared, an object whose fields are kept by object: a mutable struct with a field of an abstract type, or an immutable struct of such)
function leads_to_slots_type(@nospecialize(P), depth::Int = 0)
    holds_object_slots(P) && return true
    (depth < 2 && P isa DataType && isconcretetype(P) && isstructtype(P) && !ismutabletype(P) && tracked_object_type(P)) || return false
    for i in 1:fieldcount(P) # (a loop: see `meets_any`)
        leads_to_slots_type(fieldtype(P, i), depth + 1) && return true
    end
    return false
end

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
    entered(mi) = mi === rootmi || (sig = Base.unwrap_unionall(mi.specTypes); sig isa DataType && !isempty(sig.parameters) && is_listed(sig.parameters[1], cfunctions))
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

# (whether `F` is one of `list`, by `===`. A loop: see `meets_any`)
function is_listed(@nospecialize(F), list)
    for G in list
        G === F && return true
    end
    return false
end

# (the object that the fields `path` of `x` lead to, where those are fields that do not change, or `nothing`)
function follow_fields(c::Compilation, @nospecialize(x), path)
    for name in path
        T = typeof(x)
        (isstructtype(T) && Base.fieldindex(T, name, false) != 0 && isdefined(x, name)) || return nothing
        ismutabletype(T) && written_in(c.objects.use_written, T, name) && return nothing # (not asked by inference: see `field_written`)
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
function object_field_type(c::Compilation, argtypes::Vector{Any}, @nospecialize(sv) = nothing)
    o = c.objects
    length(argtypes) == 3 || return nothing
    t = argtypes[3]
    (t isa Core.Const && t.val isa Symbol) || return nothing
    r = known_object(c, argtypes[2])
    r === nothing && return nothing
    x = r.x
    S = typeof(x)
    name = t.val
    object_slot(S, name) || return nothing
    depends!(c, sv, (:objready,)) # (see reuse.jl)
    o.ready || return nothing
    push!(o.asked_fields, (r, name)) # (see `objects_hash`)
    depends!(c, sv, (:objfield, r, name))
    stored = field_answer(o.use_stores, o.use_unattributed, o.use_unknown, r, name)
    stored === nothing && return nothing
    T = isdefined(x, name) ? stored_value_type(getfield(x, name)) : Union{}
    T = Union{T, stored}
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
    if c !== nothing && c.settings.objects && !result.edgecycle && any(a -> a isa Core.Const && leads_to_object_slots(c, a.val), arginfo.argtypes)
        depends!(c, sv, (:objready,)); depends!(c, sv, (:mode,)) # (see reuse.jl)
        if c.objects.ready && c.slots.mode === :on
            mi = CC.specialize_method(match; preexisting = false)
            mi isa Core.MethodInstance && return mi
        end
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
    arginfo.fargs === nothing && return nothing # (as for `object_call_plan`: only a call that is a statement is replaced)
    c = CURRENT_COMPILATION[]
    (c !== nothing && keys_on(c)) || return nothing
    x = argtypes[2].val
    g = try Base.invokelatest(keyed_method, f, x) catch; nothing end
    g === nothing && return nothing
    # (the call `g(key, args...)` in its place: see "Calls that are replaced" in dispatch.jl)
    return redirect(interp, g, Any[object_key!(c, x)], 3, arginfo, si, vtypes, sv)
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
        depends!(c, sv, (:closures,)) # (what `g` gives is of the compilation: the listeners that are compared with, see closures.jl and reuse.jl)
        t = try Base.invokelatest(g, argtypes[3].val) catch; nothing end
        # (a value of bits that has a size has no key: it is not an object of the program that code refers to, but a value, which the code would have as one of this process. Then there are none, and the code does without)
        t isa Tuple && !any(keyless, t) && return const_call(map(x -> object_key!(c, x), t))
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# (in the code before it is optimized: the constant that a call of `object_for` or `known_object_keys` gives, which the statement is, or `nothing`. The calls of `setindex!` and `notify` that are made for an object are replaced
# as the others that are: see "Calls that are replaced" in dispatch.jl)
function keyed_replacement(c::Compilation, @nospecialize(called), call::Expr, @nospecialize(info), @nospecialize(t))
    (called === object_for || called === known_object_keys) || return nothing
    return t isa CC.Const ? QuoteNode(t.val) : nothing
end

## Any function, for each object
##
## What a package does with the objects that the program has as constants is often a recursion over them (`resolve!(node)` resolves what the node comes from, which resolves what that comes from): Julia propagates the
## constant into the first call, and not into the second, as the method is already being inferred with another constant (`is_constprop_edge_recursed`), and what it propagates is only used where the call is inlined. A call
## `f(x, args...)` with an object `x` that is a constant is made `object_call(f, key, Val(T), Val(C), args...)` (see "Calls that are replaced" in dispatch.jl): a method of its own for each object (the key is a type of its own
## for each), whose code is that of the method of `f` for the types (`ObjectCallGenerator`), with `x` read from the key (`object_for(key)`, the object as a constant). The other arguments that are constants that a type can
## have as a parameter (a name, a number: `getproperty(x, :field)`) are in `C`, `(position, value)` for each, and are constants in the code too; the others are given as they are. Recursion over the objects is then an ordinary
## one, of methods, as finite as the objects. The code that is made depends on the types only (and the world), not on the compilation: the object is the constant that `object_for` gives in it.
const OBJECT_CALL_MAX_ARGS = 8

struct ObjectCallGenerator <: Core.CachedGenerator end

for n in 0:OBJECT_CALL_MAX_ARGS
    args = [Symbol(:a, k) for k in 1:n]
    @eval function object_call(f, key::ObjectKey, t::Val, c::Val, $(args...))
        $(Expr(:meta, :generated, ObjectCallGenerator()))
        $(Expr(:meta, :generated_only))
    end
end

# (a constant that is put in the code as a parameter of the type of an argument: a name only. A name is one that the code has, of which there are as many as the code says; a number is not (`walk(x.next, depth + 1)`
# is a number of its own at each level, and so a method of its own at each level, without end where the objects are a cycle): it is given as an argument, which Julia propagates as a constant, within its limits)
bakeable(@nospecialize(v)) = v isa Symbol

# (the method of `f` for an object of the type `T` and the arguments, if its code can be the code of `object_call`: one method, that is not a generated one and takes no varargs, whose code does not depend on its static
# parameters in ways that the code of another method can not have (`transplantable`). It is looked for as the compiler does: in the overrides of this package (`method_table`, which the extensions add to), and then in Julia's)
function object_call_method(@nospecialize(F), @nospecialize(T), args, world::UInt)
    sig = Tuple{F,T,args...}
    found = try CC.findsup(sig, CC.OverlayMethodTable(world, method_table)) catch; nothing end
    found === nothing && return nothing
    match = found[1]
    match isa Core.MethodMatch || return nothing
    m = match.method
    (m.isva || isdefined(m, :generator) || m.nargs != length(args) + 2 || !isdefined(m, :source)) && return nothing
    transplantable(m, match.sparams) || return nothing
    return match
end

# (the same, once for each signature in a compilation: inference visits a call many times, in each pass)
function object_call_method(c::Compilation, @nospecialize(F), @nospecialize(T), args, world::UInt)
    key = (Tuple{F,T,args...}, world)
    cache = c.objects.call_methods
    haskey(cache, key) && return cache[key]
    return cache[key] = object_call_method(F, T, args, world)
end

# Whether the code of `m`, with the values `sparams` of its static parameters, can be the code of a method that has no static parameters (`object_call`): each is a value (one that is not is a parameter that
# the arguments do not determine, `f(x, y::Union{S,Nothing}) where S` given `nothing`, which the code throws on, and does not have as a value), and the code does not refer to them where they are not values that it computes
# with, but are part of what a statement is: the types of a call of C (`ccall(..., (Ptr{T},), v)`, which the compiler finds the parameters of in the method that it is compiling), a `@cfunction`, `@isdefined T`.
function transplantable(m::Method, sparams::Core.SimpleVector)
    isempty(sparams) && return true
    any(p -> p isa TypeVar || p isa Core.SimpleVector, sparams) && return false # (a parameter that is not determined: a `TypeVar`, or as Julia 1.14 has it in a match, `svec(S, false)`)
    for st in Base.uncompressed_ir(m).code
        refers_to_parameters(st) && return false
    end
    return true
end
refers_to_parameters(@nospecialize(x)) =
    x isa Expr && (x.head === :foreigncall || x.head === :cfunction || x.head === :isdefined || x.head === :new_opaque_closure || x.head === :method || any(refers_to_parameters, x.args))

function (::ObjectCallGenerator)(world::UInt, source, @nospecialize(self), @nospecialize(F), @nospecialize(K), @nospecialize(V), @nospecialize(CV), @nospecialize(given...))
    T = V.parameters[1]
    consts = CV.parameters[1]::Tuple
    norig = length(given) + length(consts) # (the arguments of the method after the object)
    # (the type of each argument of the method after the object, and where each is: a constant, or the one of `object_call` that it is given as)
    types = Vector{Any}(undef, norig)
    baked = Dict{Int,Any}(p => v for (p, v) in consts)
    runtime = Int[]
    for p in 1:norig
        if haskey(baked, p)
            types[p] = Core.Typeof(baked[p])
        else
            push!(runtime, p)
            types[p] = given[length(runtime)]
        end
    end
    match = object_call_method(F, T, types, world)
    match === nothing && return object_call_fallback(source, consts, length(given))
    orig = Base.uncompressed_ir(match.method)
    no = 2 + norig                     # (the arguments of the method: itself, the object, the others)
    nn = 5 + length(given)             # (those of `object_call`: itself, `f`, the key, the type, the constants, the others that are given)
    bakedpos = sort!(collect(keys(baked)))
    nlocal = 1 + length(bakedpos)      # (the variables that the first statements set: the object, and the constants)
    function slotmap(i::Int)
        i == 1 && return 2
        i == 2 && return nn + 1
        if i <= no
            p = i - 2
            k = findfirst(==(p), bakedpos)
            k === nothing || return nn + 1 + k
            return 5 + findfirst(==(p), runtime)
        end
        return i - no + nn + nlocal
    end
    shift = nlocal
    sparams = match.sparams
    function remap(@nospecialize(x))
        if x isa Core.SlotNumber
            return Core.SlotNumber(slotmap(x.id))
        elseif x isa Core.SSAValue
            return Core.SSAValue(x.id + shift)
        elseif x isa Core.GotoNode
            return Core.GotoNode(x.label + shift)
        elseif x isa Core.GotoIfNot
            return Core.GotoIfNot(remap(x.cond), x.dest + shift)
        elseif x isa Core.ReturnNode
            return isdefined(x, :val) ? Core.ReturnNode(remap(x.val)) : x
        elseif x isa Core.EnterNode
            dest = x.catch_dest == 0 ? 0 : x.catch_dest + shift
            return isdefined(x, :scope) ? Core.EnterNode(dest, remap(x.scope)) : Core.EnterNode(dest)
        elseif x isa Core.NewvarNode
            return Core.NewvarNode(remap(x.slot))
        elseif x isa Expr
            if x.head === :static_parameter
                v = sparams[x.args[1]]
                return v isa Symbol || v isa Expr || v isa QuoteNode ? QuoteNode(v) : v
            end
            return Expr(x.head, Any[remap(a) for a in x.args]...)
        end
        return x
    end
    code = Any[Expr(:(=), Core.SlotNumber(nn + 1), Expr(:call, GlobalRef(@__MODULE__, :object_for), Core.SlotNumber(3)))]
    for (k, p) in enumerate(bakedpos)
        v = baked[p]
        push!(code, Expr(:(=), Core.SlotNumber(nn + 1 + k), v isa Symbol ? QuoteNode(v) : v))
    end
    for st in orig.code
        push!(code, remap(st))
    end
    ci = ccall(:jl_new_code_info_uninit, Ref{Core.CodeInfo}, ())
    ci.code = code
    nstmts = length(code)
    # (the lines of the statements: those of the method's, after the ones that are put first)
    stream = CC.DebugInfoStream(nothing, orig.debuginfo, length(orig.code))
    stream.def = orig.debuginfo.def
    stream.codelocs = vcat(zeros(Int32, 3 * shift), stream.codelocs)
    ci.debuginfo = Core.DebugInfo(stream, nstmts)
    ci.ssavaluetypes = nstmts
    ci.ssaflags = vcat(zeros(UInt32, shift), orig.ssaflags)
    names, flags = orig.slotnames, orig.slotflags
    ci.slotnames = Symbol[Symbol("#self#"), :f, :key, :t, :c, (names[p + 2] for p in runtime)..., names[2], (names[p + 2] for p in bakedpos)..., names[no+1:end]...]
    ci.slotflags = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, (flags[p + 2] for p in runtime)..., flags[2] | CC.SLOT_ASSIGNEDONCE, (flags[p + 2] | CC.SLOT_ASSIGNEDONCE for p in bakedpos)..., flags[no+1:end]...]
    ci.nargs = nn
    ci.isva = false
    ci.propagate_inbounds = orig.propagate_inbounds
    ci.has_fcall = orig.has_fcall
    ci.nospecializeinfer = orig.nospecializeinfer
    ci.inlining = orig.inlining
    ci.constprop = orig.constprop
    ci.purity = orig.purity
    ci.edges = Core.svec(CC.specialize_method(match))
    # (what the limits of recursion take it to be: the method of `f`, as for the code of any generated function. All of these are methods of `object_call`, and calls of different functions for the same object, `viewport(scene)` and
    # `getproperty(scene, :viewport)` in it, would otherwise be one method that calls itself, which Julia limits)
    ci.method_for_inference_limit_heuristics = match.method
    ci.min_world = world
    ci.max_world = world
    return ci
end

# (a method whose code can not be taken: the call of `f` with the object, and the constants, as constants)
function object_call_fallback(source, consts::Tuple, ngiven::Int)
    given = [Symbol(:a, k) for k in 1:ngiven]
    baked = Dict{Int,Any}(p => v for (p, v) in consts)
    args, g = Any[], 0
    for p in 1:(ngiven + length(consts))
        haskey(baked, p) ? push!(args, baked[p] isa Symbol ? QuoteNode(baked[p]) : baked[p]) : push!(args, given[g += 1])
    end
    body = Expr(:call, :f, Expr(:call, GlobalRef(@__MODULE__, :object_for), :key), args...)
    loc = LineNumberNode(Int(source.line), source.file)
    lam = Expr(:lambda, [Symbol("#self#"), :f, :key, :t, :c, given...], Expr(:var"scope-block", Expr(:block, loc, Expr(:return, body))))
    return Base.generated_body_to_codeinfo(Expr(:toplevel_pure, lam), @__MODULE__, false, loc)
end

# (whether code of its own for an object of the type `T` can know more than code for any of them, with the object as a constant, which is what Julia makes: only where it holds something that is known of an object, see
# `fold_field_read`: a field of an abstract type, or one that holds an object (which leads to more). Code for a struct of bits and arrays would be the same for each object, made again for each)
function keyable_type(c::Compilation, @nospecialize(T))
    cache = c.objects.keyable
    k = get(cache, T, nothing)
    k === nothing || return k::Bool
    found = false
    for i in 1:fieldcount(T) # (a loop: see `meets_any`)
        FT = fieldtype(T, i)
        if !isconcretetype(FT) || tracked_object_type(FT)
            found = true
            break
        end
    end
    cache[T] = found
    return found
end

# The arguments of `redirect` for a call `f(x, args...)` that is made for the object `x`, or `nothing`: `x` a constant that is an object (a struct that is not bits), `f` a function that is a constant, with one method for
# the types, of a package (not Julia's, nor this one's: their methods on objects are the accessors that the objects are read with, which are known as they are). `(f, prefix, positions)`: the arguments that are given
# (those that are not constants of `C`).
function object_call_plan(c::Compilation, interp, @nospecialize(f), arginfo::CC.ArgInfo)
    (keys_on(c) && c.settings.objects) || return nothing
    # (only a call that is a statement, whose arguments are those of the statement, which is what is replaced: not one that a splat makes (`f(x, t...)`, inferred from `Core._apply_iterate`), nor one that a replacement makes)
    arginfo.fargs === nothing && return nothing
    argtypes = arginfo.argtypes
    n = length(argtypes) - 2
    0 <= n || return nothing
    x = argtypes[2]
    (x isa Core.Const && tracked_object_type(typeof(x.val))) || return nothing
    # (not a type, nor another object of Julia's own (a binding, a `TypeVar`): what is called with those is chosen by the value, `::Type{T}`, and they are not what a package keeps its state in)
    (x.val isa Type || parentmodule(typeof(x.val)) === Core) && return nothing
    keyable_type(c, typeof(x.val)) || return nothing
    f isa Core.Builtin && return nothing
    F = typeof(f)
    Base.issingletontype(F) || return nothing
    any(a -> a isa Core.TypeofVararg, argtypes) && return nothing
    consts, positions, types = Tuple{Int,Any}[], Int[], Any[]
    for (p, t) in enumerate(argtypes[3:end])
        if t isa Core.Const && bakeable(t.val)
            push!(consts, (p, t.val)); push!(types, Core.Typeof(t.val))
        else
            push!(positions, p + 2); push!(types, CC.widenconst(t))
        end
    end
    length(positions) <= OBJECT_CALL_MAX_ARGS || return nothing
    # (the arguments that are given are of types that are concrete: a method for an argument of an abstract type is called by the runtime's convention, `jl_invoke`)
    all(i -> isconcretetype(types[i - 2]), positions) || return nothing
    match = object_call_method(c, F, typeof(x.val), types, CC.get_inference_world(interp))
    match === nothing && return nothing
    mod = Base.moduleroot(match.method.module)
    (mod === Base || mod === Core || mod === CC || mod === @__MODULE__) && return nothing
    return (object_call, Any[f, object_key!(c, x.val), Val(typeof(x.val)), Val(Tuple(consts))], positions)
end

# (whether the signature of a call has a key in it: one of a method that is compiled for an object, see above, whose recursion is not limited)
is_key_type(@nospecialize(p)) = p isa DataType && p <: ObjectKey
has_object_key(@nospecialize(sig)) = sig isa DataType && any(p -> is_key_type(p) || (p isa DataType && p <: Tuple && !(p <: Tuple{}) && any(is_key_type, p.parameters)), sig.parameters)

# The keys of a signature, in order (those of its arguments, and of the elements of a tuple that is one). A recursion of a method from a frame for other objects to these is not limited: what it can reach is as finite as the
# objects, as long as it is limited where it comes back to the same objects with other arguments (a number that changes, a tuple that grows at each level, over a cycle of objects), which Julia does as it does for any recursion.
# (The other arguments may change from one object to the next: the update of an observable sets another, of another type of value.)
function object_keys(@nospecialize(sig), out::Vector{Any} = Any[])
    sig isa DataType || return out
    # (for `object_call`, the names that are constants too (`Val{C}`): there are as many as the code has, and `setproperty!(graph, :a, x)` that sets `graph.b` is not a recursion that grows)
    length(sig.parameters) >= 5 && sig.parameters[1] === typeof(object_call) && push!(out, sig.parameters[5])
    for p in sig.parameters
        if is_key_type(p)
            push!(out, p)
        elseif p isa DataType && p <: Tuple && !(p <: Tuple{})
            object_keys(p, out)
        end
    end
    return out
end
