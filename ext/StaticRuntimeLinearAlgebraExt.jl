# What a compiled program needs in LinearAlgebra that Base's code does not give it.
#
# `LAPACK.gees!` (the Schur factorization of a real matrix) and `LAPACK.trsen!` (the reordering of one) return
# eigenvalues that are real or complex depending on the matrix, so their results are a `Union` of two tuple types, and
# `schur!` and `ordschur` splat that into `Schur(...)`, which is a call of `Core._apply_iterate` over a `Union` that
# cannot be compiled. Indexing the result instead is split by the compiler into the two cases, so `schur` returns a
# `Union` of two `Schur` types, as it does in Julia.
module StaticRuntimeLinearAlgebraExt

using StaticRuntime: StaticRuntime, @device_override
using LinearAlgebra: LinearAlgebra, BLAS, Schur, LAPACK, BlasFloat, BlasInt

@device_override function LinearAlgebra.schur!(A::StridedMatrix{<:Union{Float32, Float64, ComplexF32, ComplexF64}})
    result = LAPACK.gees!('V', A)
    return Schur(result[1], result[2], result[3])
end

@device_override function LinearAlgebra._ordschur!(T::StridedMatrix{Ty}, Z::StridedMatrix{Ty}, select::Union{Vector{Bool}, BitVector}) where {Ty<:BlasFloat}
    result = LAPACK.trsen!(convert(Vector{BlasInt}, select), T, Z)
    return (result[1], result[2], result[3])
end

@device_override function LinearAlgebra.ordschur(schur::Schur, select::Union{Vector{Bool}, BitVector})
    result = LinearAlgebra._ordschur(schur.T, schur.Z, select)
    return Schur(result[1], result[2], result[3])
end


## BLAS and LAPACK for a program made for another target than the host's (WebAssembly, or Linux made on macOS)
#
# A program for WebAssembly has no libblastrampoline to load, and one for another system or architecture than the host's would look for it at the path that it has on the host, so the functions of BLAS and LAPACK that a program uses are replaced by Julia (`replace_on_target!`: every call of the function, in a
# program for that system, is a call of the one here, with the same arguments). They are the reference algorithms, not the ones of OpenBLAS: the sums are in another order, so the last digits
# of a result can differ from the library's.

const WasmBlasFloat = Union{Float32, Float64, ComplexF32, ComplexF64}
const WasmBlasReal = Union{Float32, Float64}
const WasmBlasComplex = Union{ComplexF32, ComplexF64}

wasm_pointer(x::Ptr) = x
wasm_pointer(x::AbstractArray) = pointer(x)
wasm_start(n::Integer, inc::Integer) = inc < 0 ? (1 - n) * inc : 0
abs1(x::Real) = abs(x)
abs1(x::Complex) = abs(real(x)) + abs(imag(x))

# level 1 (the `n`, pointer and increment forms, which the ones of arrays call). The arrays are preserved while their pointers are used: without that, the loads and stores through `pointer(x)` are not
# known to be of the array, and Julia drops the stores that fill a fresh array (the results were NaN, for `axpy!` of fresh vectors, in a program for WebAssembly and in Julia).
function wasm_dot(n::Integer, X, incx::Integer, Y, incy::Integer)
    GC.@preserve X Y begin
        px, py = wasm_pointer(X), wasm_pointer(Y)
        s = zero(eltype(px))
        ix, iy = wasm_start(n, incx), wasm_start(n, incy)
        for i in 0:n-1
            s += unsafe_load(px, ix + i * incx + 1) * unsafe_load(py, iy + i * incy + 1)
        end
        return s
    end
end
function wasm_dotc(n::Integer, X, incx::Integer, Y, incy::Integer)
    GC.@preserve X Y begin
        px, py = wasm_pointer(X), wasm_pointer(Y)
        s = zero(eltype(px))
        ix, iy = wasm_start(n, incx), wasm_start(n, incy)
        for i in 0:n-1
            s += conj(unsafe_load(px, ix + i * incx + 1)) * unsafe_load(py, iy + i * incy + 1)
        end
        return s
    end
end
wasm_dotu(n::Integer, X, incx::Integer, Y, incy::Integer) = wasm_dot(n, X, incx, Y, incy)
for (name, g) in ((:dot, :wasm_dot), (:dotc, :wasm_dotc), (:dotu, :wasm_dotu))
    @eval function $g(x::AbstractArray, y::AbstractArray)
        n = length(x)
        n == length(y) || throw(DimensionMismatch("dot product arguments have lengths $n and $(length(y))"))
        return $g(n, x, stride(x, 1), y, stride(y, 1))
    end
end
function wasm_nrm2(n::Integer, X, incx::Integer)
    GC.@preserve X begin
        px = wasm_pointer(X)
        s = zero(real(eltype(px)))
        for i in 0:n-1
            s += abs2(unsafe_load(px, i * incx + 1))
        end
        return sqrt(s)
    end
end
wasm_nrm2(x::AbstractArray) = wasm_nrm2(length(x), x, stride(x, 1))
function wasm_asum(n::Integer, X, incx::Integer)
    GC.@preserve X begin
        px = wasm_pointer(X)
        s = zero(real(eltype(px)))
        for i in 0:n-1
            s += abs1(unsafe_load(px, i * incx + 1))
        end
        return s
    end
end
wasm_asum(x::AbstractArray) = wasm_asum(length(x), x, stride(x, 1))
function wasm_axpy!(n::Integer, alpha, dx, incx::Integer, dy, incy::Integer)
    GC.@preserve dx dy begin
        px, py = wasm_pointer(dx), wasm_pointer(dy)
        ix, iy = wasm_start(n, incx), wasm_start(n, incy)
        for i in 0:n-1
            unsafe_store!(py, unsafe_load(py, iy + i * incy + 1) + alpha * unsafe_load(px, ix + i * incx + 1), iy + i * incy + 1)
        end
        return dy
    end
end
function wasm_axpy!(alpha::Number, x::AbstractArray{T}, y::AbstractArray{T}) where {T}
    length(x) == length(y) || throw(DimensionMismatch("x has length $(length(x)), but y has length $(length(y))"))
    wasm_axpy!(length(x), convert(T, alpha), x, stride(x, 1), y, stride(y, 1))
    return y
end
function wasm_scal!(n::Integer, alpha, X, incx::Integer)
    GC.@preserve X begin
        px = wasm_pointer(X)
        for i in 0:n-1
            unsafe_store!(px, alpha * unsafe_load(px, i * incx + 1), i * incx + 1)
        end
        return X
    end
end
wasm_scal!(alpha, X::AbstractArray) = wasm_scal!(length(X), alpha, X, stride(X, 1))

# level 2 and 3 (the generic algorithms of LinearAlgebra, which it uses for other types of numbers)
function wasm_gemv!(trans::AbstractChar, alpha, A::AbstractVecOrMat, X::AbstractVector, beta, Y::AbstractVector)
    return LinearAlgebra._generic_matvecmul!(Y, trans, A, X, alpha, beta)
end
function wasm_gemm!(transA::AbstractChar, transB::AbstractChar, alpha, A::AbstractVecOrMat, B::AbstractVecOrMat, beta, C::AbstractVecOrMat)
    return LinearAlgebra._generic_matmatmul!(C, LinearAlgebra.wrap(A, transA), LinearAlgebra.wrap(B, transB), alpha, beta)
end
function wasm_syrk!(uplo::AbstractChar, trans::AbstractChar, alpha, A::AbstractVecOrMat, beta, C::AbstractMatrix)
    n = size(C, 1)
    product = similar(C)
    if trans == 'N'
        LinearAlgebra._generic_matmatmul!(product, A, transpose(A), true, false)
    else
        LinearAlgebra._generic_matmatmul!(product, transpose(A), A, true, false)
    end
    for j in 1:n, i in (uplo == 'U' ? (1:j) : (j:n))
        C[i, j] = iszero(beta) ? alpha * product[i, j] : alpha * product[i, j] + beta * C[i, j]
    end
    return C
end
# the solution of a triangular system `op(A) x = b`, in place
function wasm_trsv!(uplo::AbstractChar, trans::AbstractChar, diag::AbstractChar, A::AbstractMatrix, x::AbstractVector)
    n = size(A, 1)
    unit = diag == 'U'
    entry(i, j) = trans == 'N' ? A[i, j] : trans == 'C' ? conj(A[j, i]) : A[j, i]
    if (uplo == 'U') == (trans == 'N') # (the matrix that is solved with is upper triangular)
        for i in n:-1:1
            s = x[i]
            for j in i+1:n
                s -= entry(i, j) * x[j]
            end
            x[i] = unit ? s : s / entry(i, i)
        end
    else
        for i in 1:n
            s = x[i]
            for j in 1:i-1
                s -= entry(i, j) * x[j]
            end
            x[i] = unit ? s : s / entry(i, i)
        end
    end
    return x
end

# LAPACK: the LU factorization with partial pivoting, the Cholesky factorization, and the solutions with them
function wasm_getrf!(A::AbstractMatrix{T}, ipiv::AbstractVector{BlasInt}; check::Bool = true) where {T}
    m, n = size(A)
    info = 0
    for j in 1:min(m, n)
        p = j
        best = abs1(A[j, j])
        for i in j+1:m
            v = abs1(A[i, j])
            if v > best
                best = v
                p = i
            end
        end
        ipiv[j] = p
        if !iszero(A[p, j])
            if p != j
                for k in 1:n
                    A[j, k], A[p, k] = A[p, k], A[j, k]
                end
            end
            pivot = A[j, j]
            for i in j+1:m
                A[i, j] /= pivot
            end
        elseif info == 0
            info = j
        end
        for k in j+1:n
            a = A[j, k]
            for i in j+1:m
                A[i, k] -= A[i, j] * a
            end
        end
    end
    return A, ipiv, convert(BlasInt, info)
end
wasm_getrf!(A::AbstractMatrix; check::Bool = true) = wasm_getrf!(A, Vector{BlasInt}(undef, min(size(A)...)); check)
function wasm_getrs!(trans::AbstractChar, A::AbstractMatrix, ipiv::AbstractVector{BlasInt}, B::AbstractVecOrMat)
    n = size(A, 1)
    n == size(B, 1) || throw(DimensionMismatch("B has leading dimension $(size(B, 1)), but needs $n"))
    for col in 1:size(B, 2)
        b = view(B, :, col)
        if trans == 'N'
            for i in 1:n
                p = ipiv[i]
                p != i && ((b[i], b[p]) = (b[p], b[i]))
            end
            wasm_trsv!('L', 'N', 'U', A, b)
            wasm_trsv!('U', 'N', 'N', A, b)
        else
            wasm_trsv!('U', trans, 'N', A, b)
            wasm_trsv!('L', trans, 'U', A, b)
            for i in n:-1:1
                p = ipiv[i]
                p != i && ((b[i], b[p]) = (b[p], b[i]))
            end
        end
    end
    return B
end
function wasm_getri!(A::AbstractMatrix{T}, ipiv::AbstractVector{BlasInt}) where {T}
    n = size(A, 1)
    X = zeros(T, n, n)
    for i in 1:n
        X[i, i] = one(T)
    end
    wasm_getrs!('N', A, ipiv, X)
    for j in 1:n, i in 1:n
        A[i, j] = X[i, j]
    end
    return A
end
function wasm_potrf!(uplo::AbstractChar, A::AbstractMatrix{T}) where {T}
    n = size(A, 1)
    upper = uplo == 'U'
    for j in 1:n
        s = real(A[j, j])
        for k in 1:j-1
            s -= abs2(upper ? A[k, j] : A[j, k])
        end
        if !(s > 0)
            return A, convert(BlasInt, j)
        end
        d = sqrt(s)
        A[j, j] = d
        for i in j+1:n
            t = upper ? A[j, i] : A[i, j]
            for k in 1:j-1
                t -= upper ? conj(A[k, j]) * A[k, i] : A[i, k] * conj(A[j, k])
            end
            upper ? (A[j, i] = t / d) : (A[i, j] = t / d)
        end
    end
    return A, convert(BlasInt, 0)
end
function wasm_potrs!(uplo::AbstractChar, A::AbstractMatrix, B::AbstractVecOrMat)
    for col in 1:size(B, 2)
        b = view(B, :, col)
        if uplo == 'U'
            wasm_trsv!('U', 'C', 'N', A, b)
            wasm_trsv!('U', 'N', 'N', A, b)
        else
            wasm_trsv!('L', 'N', 'N', A, b)
            wasm_trsv!('L', 'C', 'N', A, b)
        end
    end
    return B
end

# triangular solves with several right-hand sides
function wasm_trsm!(side::AbstractChar, uplo::AbstractChar, transa::AbstractChar, diag::AbstractChar, alpha, A::AbstractMatrix, B::AbstractMatrix)
    m, n = size(B)
    if side == 'L'
        for j in 1:n
            b = view(B, :, j)
            alpha == 1 || (b .*= alpha)
            wasm_trsv!(uplo, transa, diag, A, b)
        end
    else
        for i in 1:m
            b = view(B, i, :)
            alpha == 1 || (b .*= alpha)
            if transa == 'C'
                b .= conj.(b)
                wasm_trsv!(uplo, 'N', diag, A, b)
                b .= conj.(b)
            else
                wasm_trsv!(uplo, transa == 'N' ? 'T' : 'N', diag, A, b)
            end
        end
    end
    return B
end
function wasm_trtrs!(uplo::AbstractChar, trans::AbstractChar, diag::AbstractChar, A::AbstractMatrix, B::AbstractVecOrMat)
    n = size(A, 1)
    if diag == 'N'
        for i in 1:n
            iszero(A[i, i]) && throw(LinearAlgebra.SingularException(i))
        end
    end
    for j in 1:size(B, 2)
        wasm_trsv!(uplo, trans, diag, A, view(B, :, j))
    end
    return B
end

# QR: Householder reflectors `H = I - tau v v'` with `v = [1; A[i+1:m, i]]`, as LAPACK has them (so that the factors are the ones that LAPACK gives)
function householder!(A::AbstractMatrix{T}, i::Integer) where {T}
    m = size(A, 1)
    alpha = A[i, i]
    xnorm = zero(real(T))
    for r in i+1:m
        xnorm += abs2(A[r, i])
    end
    xnorm = sqrt(xnorm)
    if iszero(xnorm) && iszero(imag(alpha))
        return zero(T)
    end
    beta = -copysign(sqrt(abs2(alpha) + xnorm^2), real(alpha))
    tau = T <: Complex ? complex((beta - real(alpha)) / beta, -imag(alpha) / beta) : T((beta - alpha) / beta)
    scale = inv(alpha - beta)
    for r in i+1:m
        A[r, i] *= scale
    end
    A[i, i] = beta
    return tau
end
# `A[i:end, cols] = H' * A[i:end, cols]` (or `H *`) with the reflector that is in column `i` of `V`
function reflect_left!(C::AbstractMatrix, V::AbstractMatrix, i::Integer, tau, cols, adjoint::Bool)
    iszero(tau) && return C
    m = size(V, 1)
    t = adjoint ? conj(tau) : tau
    for j in cols
        w = C[i, j]
        for r in i+1:m
            w += conj(V[r, i]) * C[r, j]
        end
        w *= t
        C[i, j] -= w
        for r in i+1:m
            C[r, j] -= V[r, i] * w
        end
    end
    return C
end
function reflect_right!(C::AbstractMatrix, V::AbstractMatrix, i::Integer, tau, adjoint::Bool)
    iszero(tau) && return C
    n = size(V, 1)
    t = adjoint ? conj(tau) : tau
    for r in 1:size(C, 1)
        w = C[r, i]
        for k in i+1:n
            w += C[r, k] * V[k, i]
        end
        w *= t
        C[r, i] -= w
        for k in i+1:n
            C[r, k] -= w * conj(V[k, i])
        end
    end
    return C
end
function wasm_geqp3!(A::AbstractMatrix{T}, jpvt::AbstractVector{BlasInt}, tau::AbstractVector{T}) where {T}
    m, n = size(A)
    for j in 1:n
        jpvt[j] = j
    end
    for i in 1:min(m, n)
        # (the column with the largest norm of what is left of it)
        best, p = -one(real(T)), i
        for j in i:n
            nrm = zero(real(T))
            for r in i:m
                nrm += abs2(A[r, j])
            end
            if nrm > best
                best, p = nrm, j
            end
        end
        if p != i
            for r in 1:m
                A[r, i], A[r, p] = A[r, p], A[r, i]
            end
            jpvt[i], jpvt[p] = jpvt[p], jpvt[i]
        end
        tau[i] = householder!(A, i)
        reflect_left!(A, A, i, tau[i], i+1:n, true)
    end
    return A, tau, jpvt
end
wasm_geqp3!(A::AbstractMatrix{T}, jpvt::AbstractVector{BlasInt}) where {T} = wasm_geqp3!(A, jpvt, Vector{T}(undef, min(size(A)...)))
wasm_geqp3!(A::AbstractMatrix) = wasm_geqp3!(A, zeros(BlasInt, size(A, 2)))
function wasm_ormqr!(side::AbstractChar, trans::AbstractChar, A::AbstractMatrix, tau::AbstractVector, C::AbstractMatrix)
    k = length(tau)
    adjoint = trans != 'N'
    if side == 'L'
        for i in (adjoint ? (1:k) : (k:-1:1))
            reflect_left!(C, A, i, tau[i], 1:size(C, 2), adjoint)
        end
    else
        for i in (adjoint ? (k:-1:1) : (1:k))
            reflect_right!(C, A, i, tau[i], adjoint)
        end
    end
    return C
end
# the incremental estimate of the condition number (`dlaic1`), for real numbers
function wasm_laic1!(job::Integer, x::AbstractVector{T}, sest::T, w::AbstractVector{T}, gamma::T) where {T<:Union{Float32,Float64}}
    eps = Base.eps(T) / 2
    alpha = zero(T)
    for i in eachindex(x)
        alpha += x[i] * w[i]
    end
    absalp, absgam, absest = abs(alpha), abs(gamma), abs(sest)
    s = c = sestpr = zero(T)
    if job == 1
        if iszero(sest)
            s1 = max(absgam, absalp)
            if iszero(s1)
                s, c, sestpr = zero(T), one(T), zero(T)
            else
                s, c = alpha / s1, gamma / s1
                tmp = sqrt(s * s + c * c)
                s /= tmp
                c /= tmp
                sestpr = s1 * tmp
            end
        elseif absgam <= eps * absest
            s, c = one(T), zero(T)
            tmp = max(absest, absalp)
            s1, s2 = absest / tmp, absalp / tmp
            sestpr = tmp * sqrt(s1 * s1 + s2 * s2)
        elseif absalp <= eps * absest
            s1, s2 = absgam, absest
            if s1 <= s2
                s, c, sestpr = one(T), zero(T), s2
            else
                s, c, sestpr = zero(T), one(T), s1
            end
        elseif absest <= eps * absalp || absest <= eps * absgam
            s1, s2 = absgam, absalp
            if s1 <= s2
                tmp = s1 / s2
                s = sqrt(one(T) + tmp * tmp)
                sestpr = s2 * s
                c = (gamma / s2) / s
                s = copysign(one(T), alpha) / s
            else
                tmp = s2 / s1
                c = sqrt(one(T) + tmp * tmp)
                sestpr = s1 * c
                s = (alpha / s1) / c
                c = copysign(one(T), gamma) / c
            end
        else
            zeta1, zeta2 = alpha / absest, gamma / absest
            b = (one(T) - zeta1 * zeta1 - zeta2 * zeta2) / 2
            c = zeta1 * zeta1
            t = b > 0 ? c / (b + sqrt(b * b + c)) : sqrt(b * b + c) - b
            sine, cosine = -zeta1 / t, -zeta2 / (one(T) + t)
            tmp = sqrt(sine * sine + cosine * cosine)
            s, c = sine / tmp, cosine / tmp
            sestpr = sqrt(t + one(T)) * absest
        end
    else
        if iszero(sest)
            sestpr = zero(T)
            if max(absgam, absalp) == 0
                sine, cosine = one(T), zero(T)
            else
                sine, cosine = -gamma, alpha
            end
            s1 = max(abs(sine), abs(cosine))
            s, c = sine / s1, cosine / s1
            tmp = sqrt(s * s + c * c)
            s /= tmp
            c /= tmp
        elseif absgam <= eps * absest
            s, c, sestpr = zero(T), one(T), absgam
        elseif absalp <= eps * absest
            s1, s2 = absgam, absest
            if s1 <= s2
                s, c, sestpr = zero(T), one(T), s1
            else
                s, c, sestpr = one(T), zero(T), s2
            end
        elseif absest <= eps * absalp || absest <= eps * absgam
            s1, s2 = absgam, absalp
            if s1 <= s2
                tmp = s1 / s2
                c = sqrt(one(T) + tmp * tmp)
                sestpr = absest * (tmp / c)
                s = -(gamma / s2) / c
                c = copysign(one(T), alpha) / c
            else
                tmp = s2 / s1
                s = sqrt(one(T) + tmp * tmp)
                sestpr = absest / s
                c = (alpha / s1) / s
                s = -copysign(one(T), gamma) / s
            end
        else
            zeta1, zeta2 = alpha / absest, gamma / absest
            norma = max(one(T) + zeta1 * zeta1 + abs(zeta1 * zeta2), abs(zeta1 * zeta2) + zeta2 * zeta2)
            test = one(T) + 2 * (zeta1 - zeta2) * (zeta1 + zeta2)
            if test >= 0
                b = (zeta1 * zeta1 + zeta2 * zeta2 + one(T)) / 2
                c = zeta2 * zeta2
                t = c / (b + sqrt(abs(b * b - c)))
                sine, cosine = zeta1 / (one(T) - t), -zeta2 / t
                sestpr = sqrt(t + 4 * eps * eps * norma) * absest
            else
                b = (zeta2 * zeta2 + zeta1 * zeta1 - one(T)) / 2
                c = zeta1 * zeta1
                t = b >= 0 ? -c / (b + sqrt(b * b + c)) : b - sqrt(b * b + c)
                sine, cosine = -zeta1 / t, -zeta2 / (one(T) + t)
                sestpr = sqrt(one(T) + t + 4 * eps * eps * norma) * absest
            end
            tmp = sqrt(sine * sine + cosine * cosine)
            s, c = sine / tmp, cosine / tmp
        end
    end
    return sestpr, s, c
end
# (the least squares problems of matrices that have not the rank of their size are not solved here)
wasm_tzrzf!(A::AbstractMatrix) = error("least squares problems of rank deficient matrices are not supported in a program for WebAssembly")
wasm_ormrz!(side::AbstractChar, trans::AbstractChar, A::AbstractMatrix, tau::AbstractVector, C::AbstractMatrix) = error("least squares problems of rank deficient matrices are not supported in a program for WebAssembly")

function __init__()
    for (f, g) in ((BLAS.dot, wasm_dot), (BLAS.dotc, wasm_dotc), (BLAS.dotu, wasm_dotu), (BLAS.nrm2, wasm_nrm2), (BLAS.asum, wasm_asum), (BLAS.axpy!, wasm_axpy!), (BLAS.scal!, wasm_scal!),
                   (BLAS.gemv!, wasm_gemv!), (BLAS.gemm!, wasm_gemm!), (BLAS.syrk!, wasm_syrk!), (BLAS.trsv!, wasm_trsv!),
                   (BLAS.trsm!, wasm_trsm!), (LAPACK.trtrs!, wasm_trtrs!), (LAPACK.geqp3!, wasm_geqp3!), (LAPACK.ormqr!, wasm_ormqr!), (LAPACK.laic1!, wasm_laic1!), (LAPACK.tzrzf!, wasm_tzrzf!), (LAPACK.ormrz!, wasm_ormrz!),
                   (LAPACK.getri!, wasm_getri!), (LAPACK.getrf!, wasm_getrf!), (LAPACK.getrs!, wasm_getrs!), (LAPACK.potrf!, wasm_potrf!), (LAPACK.potrs!, wasm_potrs!))
        StaticRuntime.replace_on_target!(:cross, f, g)
    end
end

end
