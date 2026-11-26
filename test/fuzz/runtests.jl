# Fuzzing: random values and programs, each compiled and run in a process of its own, with a time limit, and compared with what Julia gives (the group `Fuzz`: see `harness.jl` for what it is run with). It is a job of its
# own in CI (the cases take long, and a case that does not finish must not stop the others).
@info "Fuzz tests:"

# The seeds that failed once, and are run every time (with random ones). Each is written with what it was.
const EMBEDFUZZ_PINNED = UInt[
    0x0000000000000688,
    0x009ba283a794c4a8,
    0x0000000000003cb2,
    0x0000000000003dd1,
    0x0000000000004538,
    0xe27e4d5b304aa4fd,
    0xacc4b98ebc087417,
]

const DISPATCHFUZZ_PINNED = UInt[]

include("harness.jl")

# the objects that are copied into the binary (`embedfuzz.jl`), and the analysis of what is in the slots of abstract types, and the dispatch over them (`dispatchfuzz.jl`)
@testset verbose=true "Fuzzing" begin
    fuzz_testset("embedfuzz", "Random values as constants (EmbedFuzz)", EMBEDFUZZ_PINNED)
    fuzz_testset("dispatchfuzz", "Random programs that fill slots of abstract types (DispatchFuzz)", DISPATCHFUZZ_PINNED)
end
