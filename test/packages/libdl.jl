# Libdl: libraries opened when the program runs (`dlopen`, `dlsym`, `dlclose`), the ones that are missing (with and without `throw_error`), and a function that is called through the pointer.

@testset "Libdl" begin
    check_cases([
        "dlopen and dlsym"            => () -> (h = Libdl.dlopen(opaque("libm")); p = Libdl.dlsym(h, :cos); Int(ccall(p, Float64, (Float64,), opaque(0.0)))),
        "dlsym of a string"           => () -> (p = Libdl.dlsym(Libdl.dlopen(opaque("libm")), opaque("sin")); Int(ccall(p, Float64, (Float64,), opaque(0.0)))),
        "dlsym_e and dlclose"         => () -> (h = Libdl.dlopen(opaque("libm")); p = Libdl.dlsym_e(h, :sin); Int(p != C_NULL) + 2 * Int(Libdl.dlclose(h))),
        "a library that is missing"   => () -> Int(Libdl.dlopen(opaque("no_such_library_xyz"); throw_error = false) === nothing),
        "dlopen_e of a missing one"   => () -> Int(Libdl.dlopen_e(opaque("no_such_library_xyz")) == C_NULL),
        "a symbol that is missing"    => () -> (h = Libdl.dlopen(opaque("libm")); Int(Libdl.dlsym(h, opaque("no_such_symbol_xyz"); throw_error = false) === nothing)),
        "an error for a missing library" => () -> (try; Libdl.dlopen(opaque("no_such_library_xyz")); 0; catch e; 1; end),
    ])
end
