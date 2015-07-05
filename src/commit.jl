export git_otype, message, tree, tree_id,
       author, committer, parent_id, parent_count, parents

function message(c::GitCommit, raw::Bool=false)
    local msg_ptr::Ptr{Uint8}
    msg_ptr = raw? ccall((:git_commit_message_raw, libgit2), Ptr{Uint8}, (Ptr{Void},), c) :
                   ccall((:git_commit_message, libgit2), Ptr{Uint8}, (Ptr{Void},), c)
    if msg_ptr == C_NULL
        return nothing
    end
    return utf8(bytestring(msg_ptr))
end

function GitTree(c::GitCommit)
    tree_ptr = Ptr{Void}[0]
    @check ccall((:git_commit_tree, libgit2), Cint, (Ptr{Ptr{Void}}, Ptr{Void}), tree_ptr, c.ptr)
    return GitTree(tree_ptr[1])
end

git_tree_id(c::GitCommit) = Oid(ccall((:git_commit_tree_id, libgit2), Ptr{Uint8}, (Ptr{Void},), c))

function author(c::GitCommit)
    ptr = ccall((:git_commit_author, libgit2), Ptr{SignatureStruct}, (Ptr{Void},), c)
    @assert ptr != C_NULL
    return Signature(ptr)
end

function committer(c::GitCommit)
    ptr = ccall((:git_commit_committer, libgit2), Ptr{SignatureStruct}, (Ptr{Void},), c)
    @assert ptr != C_NULL
    return Signature(ptr)
end

Base.parent(c::GitCommit, n::Integer) = begin
    n >= 1 || throw(ArgumentError("n must be greater than or equal to 1"))
    commit_ptr = Ptr{Void}[0]
    @check ccall((:git_commit_parent, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Cuint), commit_ptr, c, n-1)
    return GitCommit(commit_ptr[1])
end

parent_count(c::GitCommit) = int(ccall((:git_commit_parentcount, libgit2), Csize_t, (Ptr{Void},), c))
parents(c::GitCommit) = (n = parent_count(c); GitCommit[parent(c, i) for i=1:n])

function parent_id(c::GitCommit, n::Integer)
    n >= 1 || throw(ArgumentError("n must be greater than or equal to 1"))
    oid_ptr = ccall((:git_commit_parent_id, libgit2), Ptr{Uint8}, (Ptr{Void}, Cuint), c, n-1)
    return Oid(oid_ptr)
end
