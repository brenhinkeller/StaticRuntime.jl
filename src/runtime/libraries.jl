# Functions of other libraries, that `ccall`s name by library (`ccall((:erfc, libopenlibm), ...)`, as SpecialFunctions,
# and so Distributions, do), which Julia looks up when the call is first made, with `dlopen` and `dlsym` of its own
# (`ijl_lazy_load_and_lookup`).
#
# * The functions of the math library that the machine has (libm has the same names and meanings as openlibm, the one
#   that Julia has) are called by their names, and the linker finds them. The values can differ in the last bit from
#   openlibm's.
# * The functions of other libraries (a JLL: OpenSpecFun, GMP, MPFR, PCRE2, zlib, ...; a library of the user's) are
#   looked up when the program runs, by the loader (`loader.jl`): `dlopen` of the library, after those that it needs,
#   and `dlsym`. Which libraries, and where they are, is a table that is written for the program. Where a library is
#   looked for is the choice `libraries`: - `:system` (the default): at the path that it had when the program was
#   compiled (the program is not independent of that file, as it is with libblastrampoline, see below); - `:bundle`:
#   in the folder `lib` next to the program, where the files (and those that they need) are copied when compiling, and
#   then, if they are not there, at the path that they had. Not those of the libraries of the runtime of Julia itself:
#   they are what the program does not have.

using Libdl: Libdl

const LIBM_PREFIXES = ("libopenlibm", "libm.", "libm-")
const RUNTIME_LIBRARIES = ("libjulia", "libuv", "libLLVM", "libccalltest") # (those that need the Julia runtime)

# the Julia object that a constant operand refers to: the address of one, or the value of a global that holds one (a
# `load` of an address, as a variable that is not a constant is read)
function constant_object(op)
    if op isa LLVM.LoadInst
        p = LLVM.operands(op)[1]
        nodes = inttoptr_nodes(p)
        length(nodes) == 1 || return nothing
        addr = constant_address(nodes[1])
        (addr === nothing || addr < 4096) && return nothing
        safe_load(UInt(addr)) === nothing && return nothing
        addr = unsafe_load(Ptr{UInt}(UInt(addr)))
    else
        nodes = inttoptr_nodes(op)
        length(nodes) == 1 || return nothing
        addr = constant_address(nodes[1])
    end
    (addr === nothing || addr < 4096) && return nothing
    object_type(UInt(addr)) === nothing && return nothing
    return unsafe_pointer_to_objref(Ptr{Cvoid}(UInt(addr)))
end

# the path of a library as a name (a `LazyLibrary`, or a name), and its handle in this process
function library_path(lib)
    lib isa Libdl.LazyLibrary && return string(lib.path)
    lib isa AbstractString && return String(lib)
    return nothing
end

# The libraries that the program calls functions of: their paths (as they are in this process), those that each needs
# (their numbers), and the functions, as (library number, name)
struct LibraryPlan
    paths::Vector{String}
    needs::Vector{Vector{Int}}
    symbols::Vector{Tuple{Int,String}}
    lbt::Vector{Bool} # whether the library is linked to libblastrampoline, which has to be told what to forward to before the library calls BLAS
end
LibraryPlan() = LibraryPlan(String[], Vector{Int}[], Tuple{Int,String}[], Bool[])

# whether the file is linked to libblastrampoline (UMFPACK, CHOLMOD, ... call BLAS and LAPACK through it, and it is
# Julia that tells it where they are)
function links_blastrampoline(path::String)
    try
        out = Sys.isapple() ? read(`otool -L $path`, String) : Sys.islinux() ? read(`ldd $path`, String) : ""
        return occursin("libblastrampoline", out)
    catch
        return false
    end
end

# Where a library is that is part of the system: it is not copied with the program, and is found by its name
system_library(path::AbstractString) = any(p -> startswith(path, p), ("/usr/lib/", "/System/", "/lib/", "/lib64/", "/usr/lib64/", "/usr/lib32/"))

# The libraries that the library `lib` (at `path`) needs, as (library, handle) that are loaded in this process: those
# that its `LazyLibrary` has, and those that the file says (`otool -L`, or `ldd`) that are not of the system, as this
# process has them. (A library that a package names by its path, as HiGHS does, has no list: `libhighs` needs `libz` and
# `libblastrampoline` by `@rpath`, which is its own folder, where they are not.)
function library_needs(lib, path::String, libraries::Symbol)
    needs = Tuple{Any,Any}[]
    if lib isa Libdl.LazyLibrary
        deps = lib.dependencies
        deps isa AbstractVector || (deps = deps()) # (Julia 1.14: a `OncePerProcess` that makes the list)
        for d in deps
            h = try Libdl.dlopen(d, throw_error = false) catch; nothing end
            h === nothing || push!(needs, (d, h))
        end
    end
    names = String[]
    try
        if Sys.isapple()
            for line in split(read(`otool -L $path`, String), '\n')[2:end]
                m = match(r"^\s+(\S+)", line)
                m === nothing || push!(names, basename(m.captures[1]))
            end
        elseif Sys.islinux()
            # (`libfoo.so.1 => /path/libfoo.so.1 (0x...)`, or `libfoo.so.1 => not found` for one that the system's
            # loader does not find by itself, as `libblastrampoline` of a JLL is not: the name, which is that of the
            # library that is loaded, and the path where there is one)
            for line in split(read(`ldd $path`, String), '\n')
                m = match(r"^\s*(\S+)\s+=>\s+(\S+)", line)
                m === nothing && continue
                push!(names, basename(m.captures[1]))
                startswith(m.captures[2], "/") && push!(names, basename(m.captures[2]))
            end
        end
    catch
    end
    loaded = Libdl.dllist()
    for name in unique(names)
        name == basename(path) && continue
        found = findfirst(p -> basename(p) == name && !system_library(p), loaded)
        # (a library that is loaded by the name of its file, `libpng16.16.59.0.dylib`, and that others ask for by the
        # name that it says it has, `libpng16.16.dylib`: looked for among those whose file name begins as the name does)
        if found === nothing
            stem = first(split(name, '.'))
            found = findfirst(p -> !system_library(p) && startswith(basename(p), stem * ".") && library_install_name(p) == name, loaded)
        end
        found === nothing && continue
        any(n -> n[1] isa Libdl.LazyLibrary && basename(string(n[1].path)) == name, needs) && continue
        h = Libdl.dlopen(loaded[found], throw_error = false)
        h === nothing || push!(needs, (loaded[found], h))
    end
    return needs
end

# the name that a library says it has (`otool -D` of macOS, the `SONAME` of Linux), as the libraries that need it name
# it, or ""
function library_install_name(path::AbstractString)
    try
        if Sys.isapple()
            lines = split(read(`otool -D $path`, String), '\n')
            return length(lines) >= 2 ? basename(strip(lines[2])) : ""
        elseif Sys.islinux()
            m = match(r"SONAME\s+(\S+)", read(`objdump -p $path`, String))
            return m === nothing ? "" : String(m.captures[1])
        end
    catch
    end
    return ""
end

# the number of the library (a new one is added, with those that it needs before it)
function register_library!(plan::LibraryPlan, lib, handle, libraries::Symbol)
    full = Libdl.dlpath(handle)
    i = findfirst(==(full), plan.paths)
    i === nothing || return i
    push!(plan.paths, full)
    push!(plan.needs, Int[])
    push!(plan.lbt, links_blastrampoline(full))
    i = length(plan.paths)
    needs = Int[]
    for (dlib, dh) in library_needs(lib, full, libraries)
        j = register_library!(plan, dlib, dh, libraries)
        j == i || push!(needs, j)
    end
    plan.needs[i] = needs
    return i
end

# The lookups of `mod` that can be resolved: the names of those that are called by name (libm), and, of the others, the
# libraries and the functions, which the loader makes the lookups of when the program runs. The calls are replaced: by
# the function, or by `static_library_symbol(i)`.
function resolve_library_lookups!(mod::LLVM.Module; libraries::Symbol = :system)
    fns = LLVM.functions(mod)
    plan = LibraryPlan()
    getter = nothing
    sentinel = nothing
    i64 = LLVM.Int64Type()
    # the two forms of the lookup: `ijl_lazy_load_and_lookup(library object, symbol)` (a `LazyLibrary`, or a name that
    # is a constant) and `ijl_load_and_lookup(library name, symbol name, handle)` (a name that is a string)
    calls = LLVM.CallInst[]
    for f in ("ijl_lazy_load_and_lookup", "ijl_load_and_lookup")
        haskey(fns, f) || continue
        append!(calls, (LLVM.user(use) for use in LLVM.uses(fns[f]) if LLVM.user(use) isa LLVM.CallInst))
    end
    for call in calls
        ops = LLVM.operands(call)
        lib_op = ops[1]
        if LLVM.name(LLVM.called_operand(call)) == "ijl_load_and_lookup"
            libname, name = constant_cstring(lib_op), constant_cstring(ops[2])
            name === nothing && continue
            (name in RUNTIME_SHIM_FUNCTIONS || name in LIBC_FUNCTIONS || haskey(LIBJULIA_ALIASES, name)) && continue
            # (no library: the function is looked for in the ones that are loaded, as a library that was opened with
            # `RTLD_GLOBAL` has it, MPI.jl's `libmpi`: it is the library that has it now)
            libname === nothing && (libname = symbol_owner(name))
            libname === nothing && continue
            lib = libname
        else
            lib, sym = constant_object(lib_op), constant_object(ops[2])
            (sym isa Union{Symbol,String}) || continue
            name = String(sym)
        end
        path = library_path(lib)
        path === nothing && continue
        base = basename(path)
        any(p -> startswith(base, p), RUNTIME_LIBRARIES) && continue
        handle = open_library(lib)
        (handle !== nothing && Libdl.dlsym_e(handle, name) != C_NULL) || continue
        if any(p -> startswith(base, p), LIBM_PREFIXES)
            fn = declare!(mod, name, LLVM.FunctionType(LLVM.VoidType()))
            LLVM.replace_uses!(call, fn)
        else
            lib_index = register_library!(plan, lib, handle, libraries)
            index = something(findfirst(==((lib_index, name)), plan.symbols), 0)
            if index == 0
                push!(plan.symbols, (lib_index, name))
                index = length(plan.symbols)
            end
            getter === nothing && (getter = haskey(fns, "static_library_symbol") ? fns["static_library_symbol"] :
                                            LLVM.Function(mod, "static_library_symbol", LLVM.FunctionType(LLVM.PointerType(), [i64])))
            LLVM.@dispose builder = LLVM.IRBuilder() begin
                LLVM.position!(builder, LLVM.before(call))
                found = LLVM.call!(builder, LLVM.function_type(getter), getter, [LLVM.ConstantInt(i64, index - 1)])
                LLVM.replace_uses!(call, found)
            end
        end
        LLVM.erase!(call)
        # (the library was loaded from a variable, which is tested to be defined: it is, with the lookup resolved)
        if lib_op isa LLVM.LoadInst
            sentinel === nothing && (sentinel = library_sentinel(mod))
            LLVM.replace_uses!(lib_op, sentinel)
            isempty(collect(LLVM.uses(lib_op))) && LLVM.erase!(lib_op)
        end
    end
    return plan
end

# The file of the library that has the function `name` among those that are loaded (the first that the system finds), or
# `nothing` for one that is of the system or of Julia's runtime, which the lookups of other kinds take care of
function symbol_owner(name::AbstractString)
    default = Sys.isapple() ? Ptr{Cvoid}(typemax(UInt) - 1) : C_NULL # (`RTLD_DEFAULT`: -2 on macOS, 0 on Linux)
    sym = ccall(:dlsym, Ptr{Cvoid}, (Ptr{Cvoid}, Cstring), default, name)
    sym == C_NULL && return nothing
    info = zeros(UInt, 4) # (`Dl_info`: the file name is the first word)
    ccall(:dladdr, Cint, (Ptr{Cvoid}, Ptr{UInt}), sym, info) == 0 && return nothing
    info[1] == 0 && return nothing
    path = unsafe_string(Ptr{UInt8}(info[1]))
    (system_library(path) || any(p -> startswith(basename(path), p), RUNTIME_LIBRARIES)) && return nothing
    return path
end

# The handle of a library given as a `LazyLibrary` or as a name, in this process, as Julia finds it (a name like "libz"
# has the extension of the platform added, and the names of the ones that were linked with `@rpath` are looked for by
# their file name).
function open_library(lib)
    lib isa Libdl.LazyLibrary && return try Libdl.dlopen(lib, throw_error = false) catch; nothing end
    name = String(lib)
    candidates = [name, name * "." * Libdl.dlext, basename(name), basename(name) * "." * Libdl.dlext]
    for c in candidates
        h = Libdl.dlopen(c, throw_error = false)
        h === nothing || return h
    end
    return nothing
end

# a non-null pointer that stands for the library that a variable held
function library_sentinel(mod::LLVM.Module)
    g = LLVM.GlobalVariable(mod, LLVM.Int8Type(), "static_library_sentinel")
    LLVM.initializer!(g, LLVM.ConstantInt(LLVM.Int8Type(), 0))
    LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
    LLVM.constant!(g, true)
    return g
end

# The table that the loader reads (see `loader.jl`), as the text of a module
function library_table_ir(plan::LibraryPlan, libraries::Symbol)
    k, n = length(plan.paths), length(plan.symbols)
    io = IOBuffer()
    words = String[string("i64 ", k), string("i64 ", n)]
    for (j, path) in enumerate(plan.paths)
        print(io, llvm_cstring("lib.path$j", path))
        push!(words, "i64 ptrtoint (ptr @lib.path$j to i64)")
        if libraries === :bundle && !system_library(path)
            print(io, llvm_cstring("lib.base$j", basename(path)))
            push!(words, "i64 ptrtoint (ptr @lib.base$j to i64)")
        else
            push!(words, "i64 0")
        end
        if isempty(plan.needs[j])
            push!(words, "i64 0")
        else
            println(io, "@lib.needs$j = private constant [$(1 + length(plan.needs[j])) x i64] [i64 $(length(plan.needs[j])), ",
                    join(("i64 $(d - 1)" for d in plan.needs[j]), ", "), "]")
            push!(words, "i64 ptrtoint (ptr @lib.needs$j to i64)")
        end
        push!(words, plan.lbt[j] ? "i64 ptrtoint (ptr @lib.lbt to i64)" : "i64 0")
    end
    for (j, (lib, name)) in enumerate(plan.symbols)
        print(io, llvm_cstring("lib.name$j", name))
        push!(words, "i64 $(lib - 1)", "i64 ptrtoint (ptr @lib.name$j to i64)")
    end
    if any(plan.lbt)
        # (the libraries that libblastrampoline forwards to, as `blas_setup` has them: its path, how many, and for each its
        # path and suffix, or 0)
        LA = linear_algebra()
        lbt, libs = LA === nothing ? ("", Tuple{String,String}[]) : blas_setup(LA)
        print(io, llvm_cstring("lib.lbtpath", lbt))
        entries = String["i64 ptrtoint (ptr @lib.lbtpath to i64)", "i64 $(length(libs))"]
        for (j, (path, suffix)) in enumerate(libs)
            print(io, llvm_cstring("lib.lbtlib$j", path))
            push!(entries, "i64 ptrtoint (ptr @lib.lbtlib$j to i64)")
            if isempty(suffix)
                push!(entries, "i64 0")
            else
                print(io, llvm_cstring("lib.lbtsuffix$j", suffix))
                push!(entries, "i64 ptrtoint (ptr @lib.lbtsuffix$j to i64)")
            end
        end
        println(io, "@lib.lbt = private constant [$(length(entries)) x i64] [", join(entries, ", "), "], align 8")
    end
    println(io, "@_static_libs = hidden constant [$(length(words)) x i64] [", join(words, ", "), "], align 16")
    return String(take!(io))
end

const LOADER_IR = Ref{String}("")
function loader_ir()
    isempty(LOADER_IR[]) || return LOADER_IR[]
    loader = StaticCompiler.compile_llvm_module(Loader.symbol, (Int,), "static_library_symbol")
    try
        for fn in LLVM.functions(loader)
            LLVM.isdeclaration(fn) || LLVM.name(fn) == "static_library_symbol" || LLVM.linkage!(fn, LLVM.API.LLVMInternalLinkage)
        end
        for g in LLVM.globals(loader)
            LLVM.isdeclaration(g) || LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
        end
        LOADER_IR[] = string(loader)
    finally
        LLVM.dispose(loader)
    end
    return LOADER_IR[]
end

function link_libraries!(mod::LLVM.Module, plan::LibraryPlan; libraries::Symbol = :system)
    isempty(plan.symbols) && return false
    @debug "Functions of libraries, looked up when the program runs" plan.paths plan.symbols libraries
    for ir in (library_table_ir(plan, libraries), loader_ir())
        part = parse(LLVM.Module, ir)
        LLVM.datalayout!(part, LLVM.datalayout(mod))
        LLVM.triple!(part, LLVM.triple(mod))
        LLVM.link!(mod, part)
    end
    return true
end

# Copy the libraries of the program that was compiled (`plan`: what `link_runtime!` says that it calls) to the folder
# `lib` next to it (`libraries = :bundle`)
function bundle_libraries(program::AbstractString, plan::LibraryPlan)
    copied = String[]
    isempty(plan.symbols) && return copied
    dir = joinpath(dirname(abspath(program)), "lib")
    mkpath(dir)
    for path in plan.paths
        system_library(path) && continue
        target = joinpath(dir, basename(path))
        cp(path, target; force = true)
        push!(copied, target)
    end
    return copied
end

# The path of a `LazyLibrary` (`Libdl.dlpath`, which messages of warnings have, as SuiteSparse's does of a library that
# is too old) is the one that it has when compiling, which is also where the program looks for it (see `loader.jl`):
# Julia's own function loads the library by calling the function that is the library's callback, which is code of Julia.
Base.@assume_effects :foldable host_dlpath(lib::Libdl.LazyLibrary) = Libdl.dlpath(lib)

## BLAS and LAPACK, through libblastrampoline (LBT) as in Julia
#
# What `LinearAlgebra` calls is the functions of LBT, which forwards each to the library that backs it (OpenBLAS by
# default; `AppleAccelerate.jl` and `MKL.jl` change that by `BLAS.lbt_forward`). The library that a program uses is that
# which is set when it is compiled, so it is the user's: the binary does what `LinearAlgebra` and those packages do.
# When it first needs a function of LBT, it loads LBT (`dlopen`), forwards to the libraries that were forwarded to when
# compiling, in the same order and with the same suffixes, and looks the function up (`dlsym`). Julia binds a `ccall` of
# a function of a library in the same way, lazily (`ijl_lazy_load_and_lookup`): here the lookup is the
# `static_blas_symbol` below, with the names of the functions that the program calls (and nothing is loaded if it does
# not call any).
#
# So a program that calls BLAS needs, when it is run, the libraries that were used when compiling it, at the places that
# they were (they are not in the binary): LBT, and what it forwards to.

# LinearAlgebra, if it is loaded (it is, when a program calls BLAS: what is looked up is its LazyLibrary)
function linear_algebra()
    id = Base.PkgId(Base.UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e"), "LinearAlgebra")
    return get(Base.loaded_modules, id, nothing)
end

# the path of LBT, and the libraries that it forwards to now as (path, suffix), in the order that they were loaded in:
# those that something is forwarded to (a library that `clear` emptied is not)
function blas_setup(LA::Module)
    BLAS = LA.BLAS
    lbt = Base.Libc.Libdl.dlpath(BLAS.libblastrampoline)
    libs = Tuple{String,String}[]
    for lib in BLAS.get_config().loaded_libs
        any(!iszero, lib.active_forwards) && push!(libs, (lib.libname, lib.suffix))
    end
    return lbt, libs
end

# the functions of LBT that `mod` looks up (as `ccall`s are), replaced by a call of `static_blas_symbol(i)`, `i` being
# the index in the list that is returned. Done before the constants are embedded: what the call is given is not needed.
function resolve_blas_lookups!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_lazy_load_and_lookup") || return String[]
    LA = linear_algebra()
    LA === nothing && return String[]
    names = String[]
    i64 = LLVM.Int64Type()
    ptrT = LLVM.PointerType()
    getter = nothing
    for use in collect(LLVM.uses(fns["ijl_lazy_load_and_lookup"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        ops = LLVM.operands(call)
        objects = map((ops[1], ops[2])) do op
            nodes = inttoptr_nodes(op)
            length(nodes) == 1 || return nothing
            addr = constant_address(nodes[1])
            (addr === nothing || addr < 4096) && return nothing
            object_type(UInt(addr)) === nothing && return nothing
            return unsafe_pointer_to_objref(Ptr{Cvoid}(UInt(addr)))
        end
        (objects[1] === LA.BLAS.libblastrampoline && objects[2] isa Union{Symbol,String}) || continue
        name = String(objects[2])
        index = something(findfirst(==(name), names), 0)
        if index == 0
            push!(names, name)
            index = length(names)
        end
        getter === nothing && (getter = haskey(fns, "static_blas_symbol") ? fns["static_blas_symbol"] :
                                        LLVM.Function(mod, "static_blas_symbol", LLVM.FunctionType(ptrT, [i64])))
        LLVM.@dispose builder = LLVM.IRBuilder() begin
            LLVM.position!(builder, LLVM.before(call))
            found = LLVM.call!(builder, LLVM.function_type(getter), getter, [LLVM.ConstantInt(i64, index - 1)])
            LLVM.replace_uses!(call, found)
        end
        LLVM.erase!(call)
    end
    return names
end

# the IR that is a C string, as a global of the name
llvm_cstring(name, s) = "@$name = private unnamed_addr constant [$(ncodeunits(s) + 1) x i8] c\"" *
    join((b in 0x20:0x7e && b != UInt8('"') && b != UInt8('\\') ? string(Char(b)) : "\\" * uppercase(string(b, base = 16, pad = 2))
          for b in codeunits(s))) * "\\00\", align 1\n"

# `static_blas_symbol(i)`: the function of LBT of the name number `i`, loading LBT when it is needed the first time
function blas_loader_ir(lbt::String, libs, names::Vector{String})
    n = length(names)
    io = IOBuffer()
    println(io, "declare ptr @dlopen(ptr, i32)\ndeclare ptr @dlsym(ptr, ptr)\ndeclare void @static_errputs(ptr)\ndeclare void @exit(i32)")
    print(io, llvm_cstring("blas.lbt", lbt))
    print(io, llvm_cstring("blas.forward", "lbt_forward"))
    print(io, llvm_cstring("blas.noload", "Cannot load libblastrampoline (for BLAS), which was at $lbt when compiling"))
    print(io, llvm_cstring("blas.nosymbol", "A function of BLAS or LAPACK is not in libblastrampoline"))
    for (k, name) in enumerate(names)
        print(io, llvm_cstring("blas.name$k", name))
    end
    for (k, (path, suffix)) in enumerate(libs)
        print(io, llvm_cstring("blas.lib$k", path))
        print(io, llvm_cstring("blas.suffix$k", suffix))
    end
    println(io, "@blas.names = private constant [$n x ptr] [", join(("ptr @blas.name$k" for k in 1:n), ", "), "]")
    println(io, "@blas.table = internal global [$n x ptr] zeroinitializer, align 8")
    println(io, "@blas.handle = internal global ptr null, align 8")
    println(io, """
define ptr @static_blas_symbol(i64 %i) {
entry:
  %slot = getelementptr inbounds [$n x ptr], ptr @blas.table, i64 0, i64 %i
  %cached = load ptr, ptr %slot, align 8
  %have = icmp ne ptr %cached, null
  br i1 %have, label %done, label %lookup
done:
  ret ptr %cached
lookup:
  %h0 = load ptr, ptr @blas.handle, align 8
  %loaded = icmp ne ptr %h0, null
  br i1 %loaded, label %find, label %open
open:
  %h = call ptr @dlopen(ptr @blas.lbt, i32 2)
  %ok = icmp ne ptr %h, null
  br i1 %ok, label %forward, label %noload
noload:
  call void @static_errputs(ptr @blas.noload)
  call void @exit(i32 1)
  unreachable
forward:
  store ptr %h, ptr @blas.handle, align 8
  %fwd = call ptr @dlsym(ptr %h, ptr @blas.forward)""")
    for (k, (path, suffix)) in enumerate(libs)
        hint = isempty(suffix) ? "ptr null" : "ptr @blas.suffix$k"
        println(io, "  %f$k = call i32 %fwd(ptr @blas.lib$k, i32 0, i32 0, $hint)")
    end
    println(io, """
  br label %find
find:
  %h1 = load ptr, ptr @blas.handle, align 8
  %np = getelementptr inbounds [$n x ptr], ptr @blas.names, i64 0, i64 %i
  %name = load ptr, ptr %np, align 8
  %sym = call ptr @dlsym(ptr %h1, ptr %name)
  %found = icmp ne ptr %sym, null
  br i1 %found, label %store, label %nosymbol
store:
  store ptr %sym, ptr %slot, align 8
  ret ptr %sym
nosymbol:
  call void @static_errputs(ptr @blas.nosymbol)
  call void @exit(i32 1)
  unreachable
}""")
    return String(take!(io))
end

# define `static_blas_symbol` in `mod`, for the functions `names` that `resolve_blas_lookups!` found
function link_blas!(mod::LLVM.Module, names::Vector{String})
    isempty(names) && return false
    lbt, libs = blas_setup(linear_algebra())
    @debug "BLAS through libblastrampoline" lbt libs names
    blas = parse(LLVM.Module, blas_loader_ir(lbt, libs, names))
    LLVM.datalayout!(blas, LLVM.datalayout(mod))
    LLVM.triple!(blas, LLVM.triple(mod))
    LLVM.link!(mod, blas)
    return true
end

# A large call of BLAS can be cancelled when its task is (Julia 1.14: `@ccall(cancel_handler =
# (@cfunction(_cancel_handler, ...)))`, after finding out whether the BLAS has what it needs, `_cancel_detect`). There
# are no tasks, so the handler, which is a C function that calls Julia code, never runs, and there is nothing to find
# out: neither has a body.
function stub_cancel_handlers!(mod::LLVM.Module)
    changed = false
    for fn in LLVM.functions(mod)
        name = LLVM.name(fn)
        (startswith(name, "jlcapi__cancel_handler") || startswith(name, "julia__cancel_detect")) && !LLVM.isdeclaration(fn) || continue
        LLVM.return_type(LLVM.function_type(fn)) == LLVM.VoidType() || continue
        for bb in collect(LLVM.blocks(fn))
            LLVM.erase!(bb)
        end
        LLVM.@dispose builder = LLVM.IRBuilder() begin
            entry = LLVM.BasicBlock(fn, "entry")
            LLVM.position!(builder, LLVM.at_end(entry))
            LLVM.ret!(builder)
        end
        changed = true
    end
    if changed
        # (the stubs that `ccall`s are bound through are used by their globals, which are visible, and so are not
        # removed)
        for g in LLVM.globals(mod)
            name = LLVM.name(g)
            (startswith(name, "jlplt_") || startswith(name, "ccall_")) && LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
        end
        run!(GlobalDCEPass(), mod) # (what only the functions that were stubbed used)
    end
    return changed
end
