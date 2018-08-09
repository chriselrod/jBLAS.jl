

"""
Need to come up with a good way to implement this!!!
56-ish works well on Ryzen (1950x)
7-ish works well on Skylake-X (7900x)

But this is way more complicated. My whole prefetching strategy probably needs to be totally reworked. Need to study the behavior of memory and matmul implementations, I guess.
On Haswell, 10 works best for smallish matrices, and then takes a dramatic performance hit for 11 or greater. For larger matrices, performance improves.
A better model is probably more aware of the sizes of the different caches.

I think one advantage of following a recursive strategy is that you
may be able to structure it in a way so that there's a clear pattern / structure for prefetching blocks into different cache levels.
Moreover, recursive strategies are often called "cache oblivious", because they're indepdent of the cache sizes for a particular architecture. That is probably the most reasonable approach.
"""
function pick_prefetch_strategy()


end

using Base: llvmcall

# args are address, read/write, locality, cache type
@generated function prefetch(address, ::Val{Locality} = Val(1), ::Val{RorW} = Val(0)) where {Locality, RorW}
    prefetch_call_string = """%addr = inttoptr i64 %0 to i8*
    call void @llvm.prefetch(i8* %addr, i32 $RorW, i32 $Locality, i32 1)
    ret void"""
    quote
        $(Expr(:meta, :inline))
        llvmcall(("declare void @llvm.prefetch(i8* , i32 , i32 , i32 )",
        $prefetch_call_string), Cvoid, Tuple{Ptr{Cvoid}}, address)
    end
end

@generated function jmul!(D::AbstractMatrix{T}, A::AbstractMatrix{T}, X::AbstractMatrix{T}) where T
    m, n = size(A)
    p = size(X,2)
    # t_size = sizeof(T)
    # cacheline_size = 64 ÷ t_size
    # N = avx512 ? 64 ÷ t_size : 32 ÷ t_size
    rows, cols = pick_kernel_size(T)

    quote

        @boundscheck begin
            m == size(D,1) || throw(BoundsError())
            n == size(X,1) || throw(BoundsError())
            p == size(D,2) || throw(BoundsError())
        end

    end
end
function prefetch_storage(V::Type{Vec{L,T}}, CL, cache_loads, rows, cols, M, maxrc, maxcc, loc = 2, D = :pD) where {L,T}
    q1 = quote end
    q2 = quote end
    st = sizeof(T)
    for c ∈ 1:cols, cl ∈ 1:cache_loads
        push!(q1.args, :(prefetch($D + $((cl-1)*CL*st + M*(c - 1)*st + rows*st) + rc*$(rows*st) + cc*$(cols*M*st), Val($loc), Val(1))))
        push!(q2.args, :(prefetch($D + $((cl-1)*CL*st + M*(c - 1)*st + cols*M*st) + cc*$(cols*M*st), Val($loc), Val(1))))
        # prefetch() && push!(q.args, :(prefetch($(Symbol(:p, A,:_,r)) + $(M*st) , Val(3), Val(1))))
    end
    quote
        if rc != $maxrc
            $q1
        elseif cc != $maxcc
            $q2
        end
    end
end

"""
Could introducing branches in these prefetch statements slow things down?
What are the consequences of these?
Should the new row prefetch be reformulated into an ifelse statement?
"""
function prefetch_load_Aiq(V::Type{Vec{L,T}}, CL, cache_loads, rows, cols, M,N, maxrc,
                            prefetch_freq, loc = 2, A = :pA) where {L,T}
    q1 = quote end
    q2 = quote end
    st = sizeof(T)
    for cl ∈ 0:cache_loads-1
        push!(q1.args, :(prefetch($(A) + $(cl*CL*st-M*st+M*st*prefetch_freq) + rc*$(rows*st), Val($loc), Val(0))))
        push!(q2.args, :(prefetch($(A) + $(cl*CL*st-(N-prefetch_freq+1)*M*st+rows*st) + rc*$(rows*st), Val($loc), Val(0))))
    end
    quote
        if 0 < $(N-prefetch_freq) # Don't jump to new row
            $q1
        elseif rc != $maxrc # Don't prefetch if there're no more rows to prefetch
            $q2
        end
    end
end
function prefetch_load_Aq(V::Type{Vec{L,T}}, CL, cache_loads, rows, cols, M,N, maxrc,
                            prefetch_freq, loc = 2, A = :pA) where {L,T}
    q1 = quote end
    q2 = quote end
    st = sizeof(T)
    for cl ∈ 0:cache_loads-1
        push!(q1.args, :(prefetch($(A) + $(cl*CL*st-M*st+M*st*prefetch_freq) + rc*$(rows*st) + n*$(M*st), Val($loc), Val(0))) )
        push!(q2.args, :(prefetch($(A) + $(cl*CL*st-(N-prefetch_freq+1)*M*st+rows*st) + rc*$(rows*st) + n*$(M*st), Val($loc), Val(0))) )
    end
    quote
        if n < $(N-prefetch_freq) # Don't jump to new row
            $q1
        elseif rc != $maxrc # Don't prefetch if there're no more rows to prefetch
            $q2
        end
    end
end
function prefetch_load_Xq(V::Type{Vec{L,T}}, CL, rows, cols, N, maxrc, maxcc,
                            prefetch_freq, loc = 2, X = :pX) where {L,T}
    q1 = quote end
    q2 = quote end
    st = sizeof(T)
    # for c ∈ 1:cols
    #     push!(q.args, :( $(Symbol(X,:_,c)) = ($V)($(X)[n,$c + cc*$cols]) ) )
    # end
    for c ∈ 1:cols
        push!(q1.args, :(prefetch($X + ($(c*N+prefetch_freq*CL) + cc*$(cols*N) + pxn)*$st , Val($loc), Val(0))))
        push!(q2.args, :(prefetch($X + ($((cols+c-1)*N+prefetch_freq*CL) + cc*$(cols*N) + pxn)*$st , Val($loc), Val(0))))
    end
    quote
        if pxn < $(N-prefetch_freq*CL)
            $q1
        elseif cc != $maxcc # plus (cols - 1) * N, because jumping cols to the right, and starting at top
            $q2
        end
    end
end
function prefetch_load_Xiq(V::Type{Vec{L,T}}, CL, rows, cols, N, maxrc, maxcc,
                            prefetch_freq, loc = 2, X = :pX) where {L,T}
    q1 = quote end
    q2 = quote end
    st = sizeof(T)
    # for c ∈ 1:cols
    #     push!(q.args, :( $(Symbol(X,:_,c)) = ($V)($(X)[n,$c + cc*$cols]) ) )
    # end
    for c ∈ 1:cols
        push!(q1.args, :(prefetch($X + ($(c*N+prefetch_freq*CL) + cc*$(cols*N) )*$st , Val($loc), Val(0))))
        push!(q2.args, :(prefetch($X + ($((cols+c-1)*N+prefetch_freq*CL) + cc*$(cols*N))*$st , Val($loc), Val(0))))
    end
    quote
        if 0 < $(N-prefetch_freq*CL)
            $q1
        elseif cc != $maxcc # plus (cols - 1) * N, because jumping cols to the right, and starting at top
            $q2
        end
    end
end
function store_block(V::Type{Vec{L,T}}, row_loads, rows, cols, M, D::Symbol = :D) where {L,T}
    q = quote end
    st = sizeof(T)
    for c ∈ 1:cols, r ∈ 1:row_loads
        push!(q.args, :( vstore( $(Symbol(D,:_,r,:_,c)), $D + $((r-1)*L*st + M*(c - 1)*st ) + rc*$(rows*st) + cc*$(cols*M*st)) ) )
        # prefetch() && push!(q.args, :(prefetch($(Symbol(:p, A,:_,r)) + $(M*st) , Val(3), Val(1))))
    end
    q
end
function store_block(V::Type{Vec{L,T}}, row_loads, rows, cols, M, rc::Int, cc::Int, D = :D) where {L,T}
    q = quote end
    st = sizeof(T)
    for c ∈ 1:cols, r ∈ 1:row_loads
        push!(q.args, :( vstore($(Symbol(D,:_,r,:_,c)), $D + $((r-1)*L*st + M*(c - 1)*st + rc*rows*st + cc*cols*M*st)) ) )
        # prefetch() && push!(q.args, :(prefetch($(Symbol(:p, A,:_,r)) + $(M*st) , Val(3), Val(1))))
    end
    q
end
function initialize_block(V::Type{Vec{L,T}}, row_loads, rows, cols, M, N,
            D::Symbol = :D, A::Symbol = :A, X::Symbol = :X, pX::Symbol = :pX) where {L,T}
    q = quote end
    st = sizeof(T)
    # prefetch() && push!(q.args, :(prefetch($(pX) + $(c*N) + cc*$(cols*N), Val(3), Val(0))))
    for r ∈ 1:row_loads
        push!(q.args, :( $(Symbol(A,:_,r)) = vload($V, $(A) + $((r-1)*L*st) + rc*$(rows*st) )) )
        # prefetch() && push!(q.args, :(prefetch($(A) + $((r-1)*L*st-M*st + 2*M*st) + rc*$(rows*st), Val(3), Val(0))))
        # push!(q.args, :( @show $(Symbol(A,:_,r)) ))
    end
    for c ∈ 1:cols
        push!(q.args, :( @inbounds $(Symbol(X,:_,c)) = $V($X[1,$c + cc*$cols])) )
        # push!(q.args, :( $(Symbol(X,:_,c)) = ($V)(($X)[1,$c + cc*$cols]) ) )
        # push!(q.args, :( @show $(Symbol(X,:_,c)) ))
        for r ∈ 1:row_loads
            push!(q.args, :( $(Symbol(D,:_,r,:_,c)) = $(Symbol(A,:_,r))*$(Symbol(X,:_,c)) ) )
            # push!(q.args, :( @show $(Symbol(D,:_,r,:_,c)) ))
        end
    end
    q
end
function initialize_block(V::Type{Vec{L,T}}, row_loads, rows, cols, M, N, rc::Int, cc::Int,
            D::Symbol = :D, A::Symbol = :A, X::Symbol = :X, pX::Symbol = :pX) where {L,T}
    q = quote end
    st = sizeof(T)
    # prefetch() && push!(q.args, :(prefetch($(pX) + $(c*N) + cc*$(cols*N), Val(3), Val(0))))
    for r ∈ 1:row_loads
        push!(q.args, :( $(Symbol(A,:_,r)) = vload($V, $(A) + $((r-1)*L*st + rc*rows*st) )) )
        # prefetch() && push!(q.args, :(prefetch($(A) + $((r-1)*L*st-M*st + 2*M*st) + rc*$(rows*st), Val(3), Val(0))))
        # push!(q.args, :( @show $(Symbol(A,:_,r)) ))
    end
    for c ∈ 1:cols
        push!(q.args, :( @inbounds $(Symbol(X,:_,c)) = $V($X[1,$(c + cc*cols)]) ))
        # push!(q.args, :( @inbounds $(Symbol(X,:_,c)) = ($V)(($X)[1,$(c + cc*cols)]) ) )
        # push!(q.args, :( @show $(Symbol(X,:_,c)) ))
        for r ∈ 1:row_loads
            push!(q.args, :( $(Symbol(D,:_,r,:_,c)) = $(Symbol(A,:_,r))*$(Symbol(X,:_,c)) ) )
            # push!(q.args, :( @show $(Symbol(D,:_,r,:_,c)) ))
        end
    end
    q
end
function fma_increment_block(V::Type{Vec{L,T}}, row_loads, rows, cols, M, N,
                        D::Symbol = :D, A::Symbol = :A, X::Symbol = :X) where {L,T}
    q = quote end
    st = sizeof(T)
    # prefetch() && push!(q.args, :(prefetch($(pX) + $(c*N) + cc*$(cols*N), Val(3), Val(0))))
    for r ∈ 1:row_loads
        push!(q.args, :( $(Symbol(:p, A,:_,r)) = $(A) + $((r-1)*L*st-M*st) + rc*$(rows*st) + n*$(M*st) ))
        push!(q.args, :( $(Symbol(A,:_,r)) = vload($V, $(Symbol(:p, A,:_,r)) )) )
        # prefetch() && push!(q.args, :(prefetch($(Symbol(:p, A,:_,r)) + $(M*st) , Val(3), Val(0))))
        # + $(r*vector_length*st-M*st) + rc*$(rows*st) + n*$(M*st) )) )
        # push!(q.args, :( @show $(Symbol(A,:_,r)) ))
    end
    for c ∈ 1:cols
        push!(q.args, :( @inbounds $(Symbol(X,:_,c)) = $V($X[n,$c + cc*$cols])) )
        # push!(q.args, :( $(Symbol(X,:_,c)) = ($V)($(X)[n,$c + cc*$cols]) ) )
        # push!(q.args, :( @show $(Symbol(X,:_,c)) ))
        for r ∈ 1:row_loads
            push!(q.args, :( $(Symbol(D,:_,r,:_,c)) = fma( $(Symbol(A,:_,r)),$(Symbol(X,:_,c)),$(Symbol(D,:_,r,:_,c))) ) )
            # push!(q.args, :( @show $(Symbol(D,:_,r,:_,c)) ))
        end
    end
    q
end

function fma_increment_block(V::Type{Vec{L,T}}, row_loads, rows, cols, M, N, rc::Int, cc::Int, n::Int,
                            D::Symbol = :D, A::Symbol = :A, X::Symbol = :X) where {L,T}
    q = quote end
    st = sizeof(T)
    # prefetch() && push!(q.args, :(prefetch($(pX) + $(c*N) + cc*$(cols*N), Val(3), Val(0))))
    for r ∈ 1:row_loads
        push!(q.args, :( $(Symbol(:p, A,:_,r)) = $(A) + $((r-1)*L*st-M*st + rc*rows*st + n*M*st) ))
        push!(q.args, :( $(Symbol(A,:_,r)) = vload($V, $(Symbol(:p, A,:_,r)) )) )
        # prefetch() && push!(q.args, :(prefetch($(Symbol(:p, A,:_,r)) + $(M*st) , Val(3), Val(0))))
        # + $(r*vector_length*st-M*st) + rc*$(rows*st) + n*$(M*st) )) )
        # push!(q.args, :( @show $(Symbol(A,:_,r)) ))
    end
    for c ∈ 1:cols
        push!(q.args, :( @inbounds @inbounds $(Symbol(X,:_,c)) = $V($X[$n,$(c + cc*cols)])) )
        # push!(q.args, :( @inbounds $(Symbol(X,:_,c)) = ($V)($(X)[$n,$(c + cc*cols)]) ) )
        # push!(q.args, :( @show $(Symbol(X,:_,c)) ))
        for r ∈ 1:row_loads
            push!(q.args, :( $(Symbol(D,:_,r,:_,c)) = fma( $(Symbol(A,:_,r)),$(Symbol(X,:_,c)),$(Symbol(D,:_,r,:_,c))) ) )
            # push!(q.args, :( @show $(Symbol(D,:_,r,:_,c)) ))
        end
    end
    q
end


@generated function jmulkernel!(D::MMatrix{M,P,T}, A::MMatrix{M,N,T}, X::MMatrix{N,P,T}) where {T,M,N,P}

    vector_length, rows, cols = pick_kernel_size(T) #VL = VecLength
    V = Vec{vector_length, T}
    row_loads = rows ÷ vector_length
    q = quote
        # pD = pointer(D)
        pA = pointer(A)
        pD = pointer(D)
        @inbounds begin
            $(initialize_block(V, row_loads, rows, cols, M, N, 0, 0, :pD, :pA))
        end
        D
    end
    qa = q.args[6].args[3].args
    for n ∈ 2:N
        push!(qa, fma_increment_block(V, row_loads, rows, cols, M, N, 0,0,n, :pD, :pA))
    end
    push!(qa, store_block(V, row_loads, rows, cols, M, 0, 0, :pD))

    q
end

# Was deprecated in 0.7
# @inline sub2ind((M,N)::Tuple{Int,Int}, i, j) = i + (j-1)*M

# @generated function smul!(D::SizedArray{Tuple{M,P},T}, A::SizedArray{Tuple{M,N},T}, X::SizedArray{Tuple{N,P},T}) where {T,M,N,P}

"""
jmul!(D::MMatrix{M,P,T}, A::MMatrix{M,N,T}, X::MMatrix{N,P,T},
    ::Val{Aprefetch_freq} = Val(7), ::Val{Xprefetch_freq} = Val(7),
    ::Val{A_loc} = Val(3), ::Val{X_loc} = Val(3), ::Val{D_loc} = Val(3))

It may take some playing with the prefetching arguments.

jmul!(D, A, X)

calculates D = A * X


jmul!(D, A, X, Val(Aprefetch), Val(Xprefetch))

The prefetch val options determine the prefetch lag. That is, how far in advance will a prefetch instruction be sent?

Prefetching needs serious work on Haswell processors.
Likely, on every intel non-avx512 processors.
"""
@generated function jmul!(D::MMatrix{M,P,T}, A::MMatrix{M,N,T}, X::MMatrix{N,P,T},
    ::Val{Aprefetch_freq} = Val(7), ::Val{Xprefetch_freq} = Val(7),
    ::Val{A_loc} = Val(3), ::Val{X_loc} = Val(3), ::Val{D_loc} = Val(3)) where {T,M,N,P,Aprefetch_freq,Xprefetch_freq,A_loc,X_loc,D_loc}#,Aprefetch_freq2,Xprefetch_freq2,A_loc2,X_loc2}
    # ,::Val{Aprefetch_freq2} = Val(8), ::Val{Xprefetch_freq2} = Val(8),
    # ::Val{A_loc2} = Val(2), ::Val{X_loc2} = Val(2)) where {T,M,N,P,Aprefetch_freq,Xprefetch_freq,A_loc,X_loc,D_loc,Aprefetch_freq2,Xprefetch_freq2,A_loc2,X_loc2}

    # Preftech freq actually very architecture dependendent!!!
    # Going to have to pick that somehow, too.
    # For now, if it isn't AVX512, we'll assume it should be much less aggressive.

# @generated function smul!(D::SizedArray{Tuple{M,P},T}, A::SizedArray{Tuple{M,N},T}, X::SizedArray{Tuple{N,P},T}) where {T,M,N,P}
    # t_size = sizeof(T)
    # cacheline_size = 64 ÷ t_size
    # N = avx512 ? 64 ÷ t_size : 32 ÷ t_size
    vector_length, rows, cols = pick_kernel_size(T) #VL = VecLength

    if architecture == :Ryzen #Should make
        Aprefetch_freq *= 8
        Xprefetch_freq *= 8
    end


    row_chunks, row_remainder = divrem(M, rows)
    col_chunks, col_remainder = divrem(P, cols)

    row_loads = rows ÷ vector_length
    # col_loads = cols ÷
    V = Vec{vector_length, T}

    init_block = initialize_block(V, row_loads, rows, cols, M, N, :pD, :pA)#, :pX)
    fma_block = fma_increment_block(V, row_loads, rows, cols, M, N, :pD, :pA)#, :pX)
    store = store_block(V, row_loads, rows, cols, M, :pD)
        # init_block = initialize_block(V, row_loads, rows, cols)#, :pD, :pA, :pX)
        # fma_block = fma_increment_block(V, row_loads, rows, cols, M)#, :pD, :pA, :pX)
        # store = store_block(V, row_loads, rows, cols, M)#, :pD)

    cache_length = CACHELINE_SIZE ÷ sizeof(T)
    cache_loads = rows ÷ cache_length
    # prefetch_freq = 8
    maxrc, maxcc = row_chunks-1, col_chunks-1
    prefetch_store = prefetch_storage(V, cache_length, cache_loads, rows, cols, M, maxrc, maxcc, D_loc)


    prefetch_load_A = prefetch_load_Aq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq, A_loc)
    prefetch_load_Ai = prefetch_load_Aiq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq, A_loc)
    prefetch_load_X = prefetch_load_Xq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq, X_loc)
    prefetch_load_Xi = prefetch_load_Xiq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq, X_loc)


    # prefetch_load_A2 = prefetch_load_Aq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq2, A_loc2)
    # prefetch_load_Ai2 = prefetch_load_Aiq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq2, A_loc2)
    # prefetch_load_X2 = prefetch_load_Xq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq2, X_loc2)
    # prefetch_load_Xi2 = prefetch_load_Xiq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq2, X_loc2)

    # purpose of this is to break iteration of N up into these chunks, to prefetch X vectors.
    Nd, Nr = divrem(N-1, cache_length)
    Nr += 1
    if Nr < cache_length ÷ 3 && Nd > 0
        Nr += cache_length
        Nd -= 1
    end


    q = quote
        # pD = pointer(D)
        pA = pointer(A)
        pX = pointer(X)
        pD = pointer(D)
        @inbounds begin
            for cc ∈ 0:$(col_chunks-1), rc ∈ 0:$(row_chunks-1) #row_chunks total
                $prefetch_load_Xi
                $prefetch_load_Ai
                # $prefetch_load_Xi2
                # $prefetch_load_Ai2
                $init_block
                for n ∈ 2:$Nr
                    $prefetch_load_A
                    # $prefetch_load_A2
                    $fma_block
                end
                for nd ∈ 1:$Nd
                    pxn = (nd-1)*$cache_length+$Nr
                    $prefetch_load_X
                    # $prefetch_load_X2
                    for n ∈ pxn+1:pxn+$cache_length
                        $prefetch_load_A
                        # $prefetch_load_A2
                        $fma_block
                    end
                end
                $store
                $prefetch_store
            end
        end
        D
    end
    # push!(q.args[6].args[3],
    # quote
    #     for cc ∈ $(P-col_remainder+1:P), rc ∈ $(M-row_remainder+1:M)# rest, should do some remaining cache line size first
    #
    #     end
    # end)

    q
end
#
# struct UnsafeArray{T,N}
#     pointer::Ptr{T}
#     UnsafeArray(p::Ptr{T},::Val{N}) where {T,N} = new{T,N}(p)
# end
#
# Base.getindex(x::UnsafeArray,i) = unsafe_load(x.pointer, i)
# Base.getindex(x::UnsafeArray{T,N},i,j) where {T,N} = unsafe_load(x.pointer, i+(j-1)*N)
# #
# @generated function jmul!(pD::Ptr{T}, pA::Ptr{T}, pX::Ptr{T},::Val{M},::Val{N},::Val{P},
#     ::Val{Aprefetch_freq} = Val(7), ::Val{Xprefetch_freq} = Val(7),
#     ::Val{A_loc} = Val(3), ::Val{X_loc} = Val(3), ::Val{D_loc} = Val(3)) where {T,M,N,P,Aprefetch_freq,Xprefetch_freq,A_loc,X_loc,D_loc}#,Aprefetch_freq2,Xprefetch_freq2,A_loc2,X_loc2}
#     # ,::Val{Aprefetch_freq2} = Val(8), ::Val{Xprefetch_freq2} = Val(8),
#     # ::Val{A_loc2} = Val(2), ::Val{X_loc2} = Val(2)) where {T,M,N,P,Aprefetch_freq,Xprefetch_freq,A_loc,X_loc,D_loc,Aprefetch_freq2,Xprefetch_freq2,A_loc2,X_loc2}
#
#     # Preftech freq actually very architecture dependendent!!!
#     # Going to have to pick that somehow, too.
#     # For now, if it isn't AVX512, we'll assume it should be much less aggressive.
#
# # @generated function smul!(D::SizedArray{Tuple{M,P},T}, A::SizedArray{Tuple{M,N},T}, X::SizedArray{Tuple{N,P},T}) where {T,M,N,P}
#     # t_size = sizeof(T)
#     # cacheline_size = 64 ÷ t_size
#     # N = avx512 ? 64 ÷ t_size : 32 ÷ t_size
#     vector_length, rows, cols = pick_kernel_size(T) #VL = VecLength
#
#     if vector_length == 4
#         Aprefetch_freq *= 8
#         Xprefetch_freq *= 8
#     end
#
#
#     row_chunks, row_remainder = divrem(M, rows)
#     col_chunks, col_remainder = divrem(P, cols)
#
#     row_loads = rows ÷ vector_length
#     # col_loads = cols ÷
#     V = Vec{vector_length, T}
#
#     init_block = initialize_block(V, row_loads, rows, cols, M, N, :pD, :pA)#, :pX)
#     fma_block = fma_increment_block(V, row_loads, rows, cols, M, N, :pD, :pA)#, :pX)
#     store = store_block(V, row_loads, rows, cols, M, :pD)
#         # init_block = initialize_block(V, row_loads, rows, cols)#, :pD, :pA, :pX)
#         # fma_block = fma_increment_block(V, row_loads, rows, cols, M)#, :pD, :pA, :pX)
#         # store = store_block(V, row_loads, rows, cols, M)#, :pD)
#
#     cache_length = 64 ÷ sizeof(T)
#     cache_loads = rows ÷ cache_length
#     # prefetch_freq = 8
#     maxrc, maxcc = row_chunks-1, col_chunks-1
#     prefetch_store = prefetch_storage(V, cache_length, cache_loads, rows, cols, M, maxrc, maxcc, D_loc)
#
#
#     prefetch_load_A = prefetch_load_Aq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq, A_loc)
#     prefetch_load_Ai = prefetch_load_Aiq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq, A_loc)
#     prefetch_load_X = prefetch_load_Xq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq, X_loc)
#     prefetch_load_Xi = prefetch_load_Xiq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq, X_loc)
#
#
#     # prefetch_load_A2 = prefetch_load_Aq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq2, A_loc2)
#     # prefetch_load_Ai2 = prefetch_load_Aiq(V, cache_length, cache_loads, rows, cols, M,N, maxrc, Aprefetch_freq2, A_loc2)
#     # prefetch_load_X2 = prefetch_load_Xq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq2, X_loc2)
#     # prefetch_load_Xi2 = prefetch_load_Xiq(V, cache_length, rows, cols, N, maxrc, maxcc, Xprefetch_freq2, X_loc2)
#
#     # purpose of this is to break iteration of N up into these chunks, to prefetch X vectors.
#     Nd, Nr = divrem(N-1, cache_length)
#     Nr += 1
#     if Nr < cache_length ÷ 3 && Nd > 0
#         Nr += cache_length
#         Nd -= 1
#     end
#
#
#     q = quote
#         # pD = Base.unsafe_convert(Ptr{$V}, pointer(D))
#         # pA = Base.unsafe_convert(Ptr{$V}, pointer(A))
#         # pX = Base.unsafe_convert(Ptr{$V}, pointer(X))
#         X = UnsafeArray(pX,Val{$N}())
#         # pD = Base.unsafe_convert(Ptr{$V}, pointer(D))
#         @inbounds begin
#             for cc ∈ 0:$(col_chunks-1), rc ∈ 0:$(row_chunks-1) #row_chunks total
#                 $prefetch_load_Xi
#                 $prefetch_load_Ai
#                 # $prefetch_load_Xi2
#                 # $prefetch_load_Ai2
#                 $init_block
#                 for n ∈ 2:$Nr
#                     $prefetch_load_A
#                     # $prefetch_load_A2
#                     $fma_block
#                 end
#                 for nd ∈ 1:$Nd
#                     pxn = (nd-1)*$cache_length+$Nr
#                     $prefetch_load_X
#                     # $prefetch_load_X2
#                     for n ∈ pxn+1:pxn+$cache_length
#                         $prefetch_load_A
#                         # $prefetch_load_A2
#                         $fma_block
#                     end
#                 end
#                 $store
#                 $prefetch_store
#             end
#         end
#         # D
#     end
#     # push!(q.args[6].args[3],
#     # quote
#     #     for cc ∈ $(P-col_remainder+1:P), rc ∈ $(M-row_remainder+1:M)# rest, should do some remaining cache line size first
#     #
#     #     end
#     # end)
#
#     q
# end
#
#
#
# # D = randn(32*20, 36*20);
# # A = randn(32*20, 32*25);
# # X = randn(32*25, 36*20);
