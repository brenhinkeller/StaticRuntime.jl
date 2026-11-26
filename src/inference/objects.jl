# The objects that the program has as constants, known one by one.
#
# Slots are by type: all `Observable{Any}` of a program are one slot, holding whatever any of them holds. The objects
# that are constants can be known better:
#
# * a read of a field of a constant object (`fold_field_read`) is the field's value, if the object is immutable or the
#   program never writes that field of any object of the type; a lookup with a constant key in a constant container that
#   the program never changes is the value (`fold_container_read`);
# * a field of an abstract type of a constant object holds its value and what is stored in that object
#   (`object_field_type`, "Stores in objects").
#
# The facts (fields written, stores) are found in each pass and used in the next, as slot types are.


# (a type whose objects are known one by one: a struct that is not a bits type, as those are values that the code makes
# by other means than `new`, `reinterpret` say, and a singleton is a constant to inference already)
tracked_object_type(@nospecialize(S)) = S isa DataType && isconcretetype(S) && isstructtype(S) && !isbitstype(S) && !(S <: Core.GenericMemory) && !(S <: Array) &&
                                         !(S <: Core.MethodInstance) && !(S <: Core.CodeInstance) && !(S <: Method) && !(S <: Core.TypeName) && !(S <: Module) && !(S <: Task)

# (kept with the method while its facts are recorded, and found again when they are replayed, as the stores in the slots
# are: a pass that takes a method from the cache does not look at its code again)
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

# The elements of a `Memory` are written (by `memoryrefset!` and the others, of a reference into it, or by a function of
# C that is given it): a fact of its type, `(M, :elements)`, as the fields of a struct are.
function note_memory_written!(c::Compilation, @nospecialize(t))
    T = CC.widenconst(t)
    T isa DataType || return
    if T <: Core.GenericMemoryRef && length(T.parameters) == 3
        T = Core.GenericMemory{T.parameters...}
    end
    T isa DataType && T <: Core.GenericMemory && isconcretetype(T) && note_written!(c, T, :elements)
    return
end

# At the end of a pass: what it found is what the next one uses. Whether that is different from what this pass used
# (another pass is then made, as for the types of the slots)
function update_objects!(c::Compilation)
    o = c.objects
    o.written_any && push!(o.written, (nothing, :*))
    # (another pass only where an answer to what inference asked is different with what this pass found: a fact that
    # nothing asked about changes nothing that is inferred)
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

# The object that a lattice element is known to be: a constant, or `nothing`. (A type that the constants have only one
# object of is not taken to be that object: constants reach programs in ways the code does not show, such as a call that
# inference ran with one (`textwidth(styled"...")`), and a method for all objects of the type would read that one's
# fields.)
function known_object(c::Compilation, @nospecialize(a))
    c.settings.objects || return nothing
    a isa Core.Const && return ObjRef(a.val)
    return nothing
end

# (whether a field is written, by the facts `written`)
written_in(written, @nospecialize(S), name::Symbol) = (S, name) in written || (S, :*) in written || (nothing, name) in written || (nothing, :*) in written

# (the same, by the facts that this pass uses, asked by inference in the frame `sv`: the answer is part of what it
# infers with, see `objects_hash` and `depends!`)
function field_written(c::Compilation, @nospecialize(sv), @nospecialize(S), name::Symbol)
    o = c.objects
    push!(o.asked_written, (S, name))
    depends!(c, sv, (:written, S, name))
    return written_in(o.use_written, S, name)
end

# (what is stored in a field of an object, by the facts: `nothing` where something of a type that is not known is, or
# the union of what is stored in it and in the objects of its type that are not known)
function field_answer(stores, unattributed, unknown, r::ObjRef, name::Symbol)
    S = typeof(r.x)
    ((r, name) in unknown || (S, name) in unknown) && return nothing
    return Union{get(stores, (r, name), Union{}), get(unattributed, (S, name), Union{})}
end

# What is read of a field of an object that is known, if it is known: the value of the field, as a constant (`nothing`
# where it is not known). `sv` is the frame of inference that reads it (`nothing`: not inference)
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
    # (only what is worth knowing as a constant: an object, which is what the reads of its fields are known of, or what
    # a field of an abstract type holds)
    (tracked_object_type(typeof(v)) || !isconcretetype(fieldtype(S, i))) || return nothing
    o = c.objects
    depends!(c, sv, (:objready,)) # (what is read is known once the facts are there: see passes.jl)
    if !o.ready
        # (another pass is made for the facts only where a read could be known and would tell inference something: a
        # field of an abstract type of a mutable object that is a constant)
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
# A lookup with a constant key in a constant container (`graph.outputs[:positions]`) is the value that the container holds
# when compiling, where the program never changes a container of its type; the code is then inferred with that value
# (the program still makes the lookup). A `Dict` changes by a write of any of its type's fields (every change of keys or
# values writes `age` or `count`) or of the elements of its values' memory (`map!` writes only those); a `Vector` by a
# write of `ref` or `size` or of its memory's elements (only for elements that are not bits: those are copied by untyped
# `memmove`). The facts are the pass before's, as for fields (`fold_field_read`).
#
# What is not seen: writes through pointers (`unsafe_store!`, C functions given an address). What is known of objects and
# containers is the references they hold, and references are not written through pointers (the collector would not see
# it: Julia has no write barrier there, and slot types assume the same). Taking the address of a `Memory`'s elements still
# counts as writing them (`note_memory_written!` of `getfield(m, :ptr)`): Julia's own copies of references go through it.
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

# What `f(container, key)` gives (`getindex`, `get` with a default), where the container is a constant that the program
# does not change and the key is a constant: as a constant, or `nothing`
function fold_container_read(c::Compilation, @nospecialize(f), argtypes::Vector{Any}, @nospecialize(sv))
    c.settings.objects || return nothing
    n = length(argtypes)
    (n == 3 || (n == 4 && f === Base.get)) || return nothing
    d, k = argtypes[2], argtypes[3]
    (d isa Core.Const && k isa Core.Const && (d.val isa Dict || (d.val isa Vector && f === Base.getindex))) || return nothing
    x, key = d.val, k.val
    # (what the lookup gives now, and whether it is worth knowing as a constant: an object, which is what the reads of
    # its fields are known of, or a value of a container of an abstract type. A key that is not there gives the default,
    # or a `KeyError`, which the call gives itself)
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
    depends!(c, sv, (:objready,)) # (see passes.jl)
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
                                          vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
        call = julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
        (sv isa CC.InferenceState || CC.isready(call)) || return call
        folded = fold_container_read(compilation(), f, arginfo.argtypes, sv)
        return folded === nothing ? call : after_call(result_of_type, call, interp, sv, folded)
    end
end

## Stores in objects
#
# What a field of a known object holds (`object_field_type`): its value when compiling, and what code stores in it. A
# store is in a known object where code has the object as a constant (`setfield!(Const(o), ...)`), or where a call gives
# the object to a method that stores in its argument (`setindex!(obs, v)` stores in `obs.val`): the calls say which object
# (`resolve_object_stores!`). A store in an unknown object (a call with one, or a call that is not seen) is in every object
# of the type (`unattributed`).

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

# (a fact of the objects: kept with the method while its facts are recorded, see `record_slot_facts!`, and applied when
# they are replayed)
function object_fact!(c::Compilation, kind::Symbol, a, b, @nospecialize(v))
    sink = c.slots.facts_sink
    sink === nothing ? apply_object_fact!(c, kind, a, b, v) : push!(sink, ((kind, a, b), v))
    return
end

function apply_object_fact!(c::Compilation, kind::Symbol, a, b, @nospecialize(v))
    o = c.objects
    # (a store of a method, that is replayed: of the program only if the code of the method is, which is known when all
    # are replayed, see `resolve_object_stores!`)
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

# A store of `T` (the value is the argument `val_arg` of the method, if it is one) in the field `name` of what the
# operand `recv` is (its type `S`, what inference has of it `lat`, and where it is read from an argument of the method,
# if it is: `(n, path)`, the fields of the argument `n` that it is read through, as `p.out` of a listener `p`)
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
        # (in the argument of a method: what its calls give it. Only in the facts that are recorded before the code is
        # optimized, which are of the method for all of its calls; the optimized code has these in its calls)
        s.facts_sink === nothing || s.fact_mi === nothing || object_fact!(c, :recvstore, (s.fact_mi, recv_arg[1]), (recv_arg[2], name), val_arg !== nothing ? val_arg : T)
        return
    end
    r = lat === nothing ? nothing : known_object(c, lat)
    r === nothing ? object_fact!(c, :unattributed, S, name, T) : object_fact!(c, :objstore, r, name, T)
    return
end

# (whether an argument of a method can be an object whose stores are kept: a mutable struct with a field of an abstract
# type)
function holds_object_slots(@nospecialize(P))
    (P isa DataType && ismutabletype(P) && tracked_object_type(P)) || return false
    for i in 1:fieldcount(P) # (a loop: see `meets_any`)
        needs_slot_type(fieldtype(P, i)) && return true
    end
    return false
end

# A call of `callee`, in the code of `mi` (before it is optimized), that gives it an object whose stores are kept: what
# each of its arguments is (see `callsites`) (whether a call of this signature gives a method an object whose stores are
# kept, asked once for each type in a compilation)
function gives_object(c::Compilation, sig::DataType)
    c.settings.objects || return false
    o = c.objects
    g = get(o.gives, sig, nothing) # (once for each signature: a method is called with the same one from many places)
    g === nothing || return g::Bool
    found = false
    for n in 1:length(sig.parameters) # (the function too: a listener, whose fields are the objects that it stores in)
        P = sig.parameters[n]
        P isa Core.TypeofVararg && continue
        # (not `get!` with a closure that has the type: a closure of each type is a method that Julia compiles, for each
        # type that is asked about)
        h = get(o.holds, P, nothing)
        h === nothing && (h = o.holds[P] = leads_to_slots_type(P))
        h::Bool && (found = true; break)
    end
    o.gives[sig] = found
    return found
end

# (whether a value of the type `P` is, or holds in its fields as they are declared, an object whose fields are kept by
# object: a mutable struct with a field of an abstract type, or an immutable struct of such)
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

# The stores in the arguments of methods, in the objects that the calls give them: from each method to its calls, and to
# theirs where they give it an argument of theirs. A method that is called by a call that is not seen (the code that
# reaches the method has it as a callee, `callers`, and no call of it was found there) stores in any object of the type.
function resolve_object_stores!(c::Compilation, rootmi)
    o = c.objects
    # (the code of a method is of the program if a call that is left in the code calls it, or it is where the program,
    # or a `@cfunction` of it, starts: a method that is only inlined is in its callers)
    cfunctions = Any[r.ftype for r in c.closures.cfunction_roots]
    entered(mi) = mi === rootmi || (sig = Base.unwrap_unionall(mi.specTypes); sig isa DataType && !isempty(sig.parameters) && is_listed(sig.parameters[1], cfunctions))
    # (any call that is left: one that gives the method no object, as `run_finalizer(Val(id), F, T, addr)` that runs a
    # finalizer, whose code is inlined in it, is not in `callsites`)
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

# (where an operand of the code before it is optimized is read from an argument of the method through fields with names
# that are constants: `(n, path)`, or `nothing`)
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

# What is read of a field of an object that is known and that the code writes: what it has when compiling, and what is
# stored in it (in it, and in an object of its type that is not known), or `nothing` where that is not known
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
    depends!(c, sv, (:objready,)) # (see passes.jl)
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

# (what inference has of an operand of the optimized code: the type of a statement, a constant; `nothing` for an
# argument, whose stores are those of the method's calls) (the optimizer widens what inference had of a statement: a
# field of an object that is known is found again, as the read was, see `fold_field_read`)
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

# A call given a known object whose fields are kept by object (`holds_object_slots`), or an immutable one that holds such
# objects (a listener, a tuple of observables), is inferred with it as a constant. Julia does not, for a mutable object or
# when the result can not be more precise (`(listener::Pair)()` gives `nothing`), and the method would then read what all
# objects of the type hold (`to_value(obs)` given one observable of an `onany`).
function CC.maybe_get_const_prop_profitable(interp::OverridesInterpreter, result::CC.MethodCallResult, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                            match::Core.MethodMatch, sv::CC.AbsIntState)
    c = CURRENT_COMPILATION[]
    if c !== nothing && c.settings.objects && !result.edgecycle && any(a -> a isa Core.Const && leads_to_object_slots(c, a.val), arginfo.argtypes)
        depends!(c, sv, (:objready,)); depends!(c, sv, (:mode,)) # (see passes.jl)
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

# (whether a read of the field `name` of what `a` is could be known as one of an object, and tell inference something: a
# field of an abstract type of a mutable object that is a constant)
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

# The object facts of a method, from its code after inlining (`ssa_inlining_pass!`), where inlined code has the objects
# that the method gives it as constants (`listener.out.val = (listener.a.val, ...)`): stores in objects, and the calls
# left (`:invoke`), which are the program's calls. They are added to the facts kept with the method.
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
            # (a call that is left as a call, of a builtin (`Core._apply_iterate` of a splat of a tuple of a union) or
            # one that is dispatched: the methods that it may reach run too, with what is inlined in them)
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
        # (the constants that the code has now: the optimizer folds a call that gives a constant (`Ok(nothing)` of a parser that is a constant) into
        # the object, which the statements before inlining, that the slot facts were made from, do not have. What it holds is stored in slots all the same)
        note_slots_in_constants!(c, (ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts)))
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

# (a store in a field of a struct, `setfield!` or a call of `setproperty!` that is left, with what the receiver and the
# value are)
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
