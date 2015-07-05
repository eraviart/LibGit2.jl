export isbare, isempty, workdir, path, init_repo, head, exists,
       set_head!, tags, tag!, commits, references, lookup,
       lookup_tree, lookup_commit, commit, ref_names,
       revparse_single, create_ref, create_sym_ref, lookup_ref,
       repo_odb, config,  GitTreeBuilder, set_workdir!,
       insert!, write!, close, lookup, revparse, revparse_oid, remotes,
       ahead_behind, is_descendant_of, merge_base, merge_commits,
       blob_at, isshallow, hash_data,
       default_signature, repo_discover, isempty, namespace, set_namespace!,
       notes, create_note!, remove_note!, note_default_ref,
       branch_names, lookup_branch, create_branch, lookup_remote,
       remote_names, remote_add!, checkout_tree!, checkout_head!, checkout!,
       is_head_detached, is_head_unborn, GitCredential, CredDefault,
       CredPlainText, CredSSHKey, repo_clone, foreach, reset!, currentstate,
       remove_untracked!, branches

typealias MaybeOid Union(Nothing, Oid)
typealias MaybeString Union(Nothing, String)
typealias MaybeSignature Union(Nothing, Signature)

GitRepo(path::String; alternates={}) = begin
    repo_ptr = Ptr{Void}[0]
    err = ccall((:git_repository_open, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Uint8}), repo_ptr, path)
    if err != GitErrorConst.GIT_OK
        if repo_ptr[1] != C_NULL
            ccall((:git_repository_free, libgit2), Void, (Ptr{Void},), repo_ptr[1])
        end
        throw(LibGitError(err))
    end
    repo = GitRepo(repo_ptr[1])
    if !isempty(alternates)
        odb = Odb(repo)
        for pth in alternates
            if !isdir(pth)
                throw(ArgumentError("alternate $path is not a valid directory"))
            end
            @check ccall((:git_odb_add_disk_alternate, libgit2), Cint,
                         (Ptr{Void}, Ptr{Uint8}), odb, pth)
        end
    end
    return repo
end

Base.show(io::IO, r::GitRepo) = begin
    write(io, "GitRepo(\"$(workdir(r))\")")
end

Base.close(r::GitRepo) = begin
    if r.ptr != C_NULL
        ccall((:git_repository__cleanup, libgit2), Void, (Ptr{Void},), r.ptr)
    end
end

Base.in(id::Oid, r::GitRepo) = exists(Odb(r), id)

function cb_iter_oids(idptr::Ptr{Uint8}, o::Ptr{Void})
    try
        produce(Oid(idptr))
        return GitErrorConst.GIT_OK
    catch err
        return GitErrorConst.ERROR
    end
end

const c_cb_iter_oids = cfunction(cb_iter_oids, Cint, (Ptr{Uint8}, Ptr{Void}))

#TODO: better error handling
Base.start(r::GitRepo) = begin
    odb = Odb(r)
    t = @task ccall((:git_odb_foreach, libgit2), Cint,
                    (Ptr{Void}, Ptr{Void}, Ptr{Cint}), odb, c_cb_iter_oids, C_NULL)
    return (consume(t), t)
end

Base.done(r::GitRepo, state) = istaskdone(state[2])

Base.next(r::GitRepo, state) = begin
    v = consume(state[2])
    return (state[1], (v, state[2]))
end

Base.read(r::GitRepo, id::Oid) = begin
    odb = Odb(r)
    obj_ptr = Ptr{Void}[0]
    @check ccall((:git_odb_read, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Oid}), obj_ptr, odb, &id)
    return OdbObject(obj_ptr[1])
end

Base.delete!(r::GitRepo, ref::GitReference) = begin
    @check ccall((:git_reference_delete, libgit2), Cint, (Ptr{Void}, Ptr{Void}), r, ref)
    return r
end

Base.delete!(r::GitRepo, t::GitTag) = begin
    @check ccall((:git_tag_delete, libgit2), Cint, (Ptr{Void}, Ptr{Uint8}), r, name(t))
    return r
end

Base.getindex(r::GitRepo, o) = lookup(r, o)

read_header(r::GitRepo, id::Oid) = read_header(Odb(r), id)

exists(r::GitRepo, ref::String) = begin
    ref_ptr = Ptr{Void}[0]
    err = ccall((:git_reference_lookup, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), ref_ptr, r, ref)
    ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), ref_ptr[1])
    if err == GitErrorConst.ENOTFOUND
        return false
    elseif err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return true
end
exists(r::GitRepo, id::Oid) = id in r

function currentstate(r::GitRepo)
    res = ccall((:git_repository_state, libgit2), Cint, (Ptr{Void},), r)
    res == 0 && return :none
    res == 1 && return :merge
    res == 2 && return :revert
    res == 3 && return :cherry_pick
    res == 4 && return :bisect
    res == 5 && return :rebase
    res == 6 && return :rebase_interactive
    res == 7 && return :rebase_merge
    res == 8 && return :apply_mailbox
    res == 9 && return :apply_mailbox_or_rebase
    error("unknown state constant $res")
end

function isbare(r::GitRepo)
    return bool(ccall((:git_repository_is_bare, libgit2), Cint, (Ptr{Void},), r))
end

Base.isempty(r::GitRepo) = begin
    return bool(ccall((:git_repository_is_empty, libgit2), Cint, (Ptr{Void},), r))
end

function isshallow(r::GitRepo)
    return bool(ccall((:git_repository_is_shallow, libgit2), Cint, (Ptr{Void},), r))
end

function workdir(r::GitRepo)
    dir = ccall((:git_repository_workdir, libgit2), Ptr{Uint8}, (Ptr{Void},), r)
    dir == C_NULL && return nothing
    # remove trailing slash
    return bytestring(dir)[1:end-1]
end

function path(r::GitRepo)
    cpath = ccall((:git_repository_path, libgit2), Ptr{Uint8}, (Ptr{Void},), r)
    cpath == C_NULL && return nothing
    # remove trailing slash
    return bytestring(cpath)[1:end-1]
end

function hash_data{T<:GitObject}(::Type{T}, content::String)
    id_ptr = [Oid()]
    @check ccall((:git_odb_hash, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Uint8}, Csize_t, Cint),
                 id_ptr, content, length(content), git_otype(T))
    return id_ptr[1]
end

function default_signature(r::GitRepo)
    sig_ptr = Ptr{SignatureStruct}[0]
    @check ccall((:git_signature_default, libgit2), Cint,
                 (Ptr{Ptr{SignatureStruct}}, Ptr{Void}), sig_ptr, r)
    sig = Signature(sig_ptr[1])
    ccall((:git_signature_free, libgit2), Void, (Ptr{SignatureStruct},), sig_ptr[1])
    return sig
end

function is_head_detached(r::GitRepo)
    return bool(ccall((:git_repository_head_detached, libgit2), Cint, (Ptr{Void},), r))
end

function is_head_unborn(r::GitRepo)
    return bool(ccall((:git_repository_head_unborn, libgit2), Cint, (Ptr{Void},), r))
end

function init_repo(path::String; bare::Bool=false)
    repo_ptr = Ptr{Void}[0]
    err = ccall((:git_repository_init, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Uint8}, Cint), repo_ptr, path, bare)
    if err != GitErrorConst.GIT_OK
        if repo_ptr[1] != C_NULL
            ccall((:git_repository_free, libgit2), Void, (Ptr{Void},), repo_ptr[1])
        end
        throw(LibGitError(err))
    end
    return GitRepo(repo_ptr[1])
end

function set_namespace!(r::GitRepo, ns)
    if ns == nothing || isempty(ns)
        @check ccall((:git_repository_set_namespace, libgit2), Cint,
                     (Ptr{Void}, Ptr{Uint8}), r, C_NULL)
    else
        @check ccall((:git_repository_set_namespace, libgit2), Cint,
                     (Ptr{Void}, Ptr{Uint8}), r, ns)
    end
    return r
end

function namespace(r::GitRepo)
    ns_ptr = ccall((:git_repository_get_namespace, libgit2), Ptr{Uint8}, (Ptr{Void},), r)
    ns_ptr == C_NULL && return nothing
    return bytestring(ns_ptr)
end

function head(r::GitRepo)
    head_ptr = Ptr{Void}[0]
    err = ccall((:git_repository_head, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}), head_ptr, r)
    if err == GitErrorConst.ENOTFOUND || err == GitErrorConst.EUNBORNBRANCH
        return nothing
    elseif err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return GitReference(head_ptr[1])
end

Oid(r::GitRepo, val::GitObject) = Oid(val)
Oid(r::GitRepo, val::Oid) = val

function Oid(r::GitRepo, val::String)
    if length(val) == OID_HEXSZ
        try
            return Oid(val)
        end
    end
    return revparse_oid(r, val)
end

function set_head!(r::GitRepo, ref::String;
                   sig::MaybeSignature=nothing,
                   logmsg::MaybeString=nothing)
    @check ccall((:git_repository_set_head, libgit2), Cint,
                 (Ptr{Void}, Ptr{Uint8}, Ptr{SignatureStruct}, Ptr{Uint8}),
                 r, ref, sig != nothing ? sig : C_NULL, logmsg != nothing ? logmsg : C_NULL)
    return r
end

commits(repo::GitRepo) = begin
    cs = GitCommit[]
    for id in repo
        obj = lookup(repo, id)
        isa(obj, GitCommit) && push!(cs, obj)
    end
    return cs
end

function remotes(r::GitRepo)
    sa_ptr = [StrArrayStruct()]
    @check ccall((:git_remote_list, libgit2), Cint,
                 (Ptr{StrArrayStruct}, Ptr{Void}), sa_ptr, r)
    sa = sa_ptr[1]
    sa.count == 0 && return nothing
    remote_ptr = Ptr{Void}[0]
    out = Array(GitRemote, sa.count)
    for i in 1:sa.count
        rstr_ptr = unsafe_load(sa.strings, i)
        @check ccall((:git_remote_load, libgit2), Cint,
                     (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), remote_ptr, r, rstr_ptr)
        out[i] = GitRemote(remote_ptr[1])
    end
    free!(sa)
    return out
end

function remote_names(r::GitRepo)
    sa_ptr = [StrArrayStruct()]
    @check ccall((:git_remote_list, libgit2), Cint,
                  (Ptr{StrArrayStruct}, Ptr{Void}), sa_ptr, r)
    sa = sa_ptr[1]
    ns = Array(UTF8String, sa.count)
    for i in 1:sa.count
        ns[i] = utf8(bytestring(unsafe_load(sa.strings, i)))
    end
    free!(sa)
    return ns
end

function remote_add!(r::GitRepo, name::String, url::String)
    check_valid_url(url)
    remote_ptr = Ptr{Void}[0]
    @check ccall((:git_remote_create, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}), remote_ptr, r, name, url)
    return GitRemote(remote_ptr[1])
end

function cb_push_status(ref_ptr::Ptr{Uint8}, msg_ptr::Ptr{Uint8}, payload::Ptr{Void})
    if msg_ptr != C_NULL
        result = unsafe_pointer_to_objref(payload)::Dict{UTF8String,UTF8String}
        result[utf8(bytestring(ref_ptr))] = utf8(bytestring(msg_ptr))
    end
    return GitErrorConst.GIT_OK
end

const c_cb_push_status = cfunction(cb_push_status, Cint,
                                   (Ptr{Uint8}, Ptr{Uint8}, Ptr{Void}))

#TODO: better error messages
Base.push!{T<:String}(r::GitRepo, remote::GitRemote, refs::Vector{T};
                      sig::MaybeSignature=nothing,
                      logmsg::MaybeString=nothing) = begin
    push_ptr = Ptr{Void}[0]
    err = ccall((:git_push_new, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}), push_ptr, remote)
    p = push_ptr[1]
    if err != GitErrorConst.GIT_OK
        if p != C_NULL
            ccall((:git_push_free, libgit2), Void, (Ptr{Void},), p)
        end
        throw(LibGitError(err))
    end
    @assert p != C_NULL
    for ref in refs
        err = ccall((:git_push_add_refspec, libgit2), Cint, (Ptr{Void}, Ptr{Uint8}), p, ref)
    end
    if err != GitErrorConst.GIT_OK
        ccall((:git_push_free, libgit2), Void, (Ptr{Void},), p)
        throw(LibGitError(err))
    end
    err = ccall((:git_push_finish, libgit2), Cint, (Ptr{Void},), p)
    if err != GitErrorConst.GIT_OK
        ccall((:git_push_free, libgit2), Void, (Ptr{Void},), p)
        if err == GitErrorConst.ENONFASTFORWARD
            error("non-fast-forward update rejected")
        elseif err == GitErrorConst.EBAREREPO
            error("could not push to repo (check for non-bare repo)")
        end
    end
    err = ccall((:git_push_unpack_ok, libgit2), Cint, (Ptr{Void},), p)
    if err == GitErrorConst.GIT_OK
        ccall((:git_push_free, libgit2), Void, (Ptr{Void},), p)
        error("remote side did not unpack successfully")
    end
    result = Dict{UTF8String, UTF8String}()
    err = ccall((:git_push_status_foreach, libgit2), Cint,
                (Ptr{Void}, Ptr{Void}, Any), p, c_cb_push_status, &result)
    if err != GitErrorConst.GIT_OK
        ccall((:git_push_free, libgit2), Void, (Ptr{Void},), p)
        throw(LibGitError(err))
    end
    err = ccall((:git_push_update_tips, libgit2), Cint,
                (Ptr{Void}, Ptr{SignatureStruct}, Ptr{Uint8}), p,
                sig != nothing ? sig : C_NULL,
                logmsg != nothing ? logmsg : C_NULL)
    if err != GitErrorConst.GIT_OK
        ccall((:git_push_free, libgit2), Void, (Ptr{Void},), p)
        throw(LibGitError(err))
    end
    return result
end

Base.push!{T<:String}(r::GitRepo, remote::String, refs::Vector{T}) = begin
    remote_ptr = Ptr{Void}[0]
    @check ccall((:git_remote_load, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), remote_ptr, r, remote)
    return push!(r, GitRemote(remote_ptr[1]), refs)
end

function lookup(::Type{GitRemote}, r::GitRepo, remote_name::String)
    remote_ptr = Ptr{Void}[0]
    err = ccall((:git_remote_load, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), remote_ptr, r, remote_name)
    if err == GitErrorConst.ENOTFOUND
        return nothing
    elseif err != GitErrorConst.GIT_OK
        if remote_ptr[1] != C_NULL
            ccall((:git_remote_free, libgit2), Void, (Ptr{Void},), remote_ptr[1])
        end
        throw(LibGitError(err))
    end
    return GitRemote(remote_ptr[1])
end

lookup_remote(r::GitRepo, remote_name::String) = lookup(GitRemote, r, remote_name)
lookup_tag(r::GitRepo, id::Oid) = lookup(GitTag, r, id)

function tags(r::GitRepo, glob::String="")
    sa_ptr = [StrArrayStruct()]
    @check ccall((:git_tag_list_match, libgit2), Cint,
                 (Ptr{StrArrayStruct}, Ptr{Uint8}, Ptr{Void}), sa_ptr, glob, r)
    sa = sa_ptr[1]
    sa.count == 0 && return GitTag[]
    out = Array(UTF8String, sa.count)
    for i in 1:sa.count
        out[i] = utf8(bytestring(unsafe_load(sa.strings, i)))
    end
    free!(sa)
    return out
end

function tag!(r::GitRepo;
              name::String="",
              message::String="",
              target::MaybeOid=nothing,
              tagger::MaybeSignature=nothing,
              force::Bool=false)
   id_ptr = [Oid()]
   target != nothing && (obj = lookup(r, target))
   if !isempty(message)
       sig = tagger != nothing ? tagger : default_signature(r)
       @check ccall((:git_tag_create, libgit2), Cint,
                    (Ptr{Oid}, Ptr{Void}, Ptr{Uint8},
                     Ptr{Void}, Ptr{SignatureStruct}, Ptr{Uint8}, Cint),
                    id_ptr, r, name, obj, sig, message, force)
   else
       @check ccall((:git_tag_create_lightweight, libgit2), Cint,
                    (Ptr{Oid}, Ptr{Void}, Ptr{Uint8}, Ptr{Void}, Cint),
                    id_ptr, r, name, obj, force)
   end
   return id_ptr[1]
end

function create_note!(
               obj::GitObject, msg::String;
               committer::MaybeSignature=nothing,
               author::MaybeSignature=nothing,
               ref::MaybeString=nothing,
               force::Bool=false)
    repo_ptr  = ccall((:git_object_owner, libgit2), Ptr{Void}, (Ptr{Void},), obj)
    bref = ref != nothing ? bytestring(ref) : convert(Ptr{Uint8}, C_NULL)
    #TODO: we can avoid having to lookup the default signature twice
    local committer_ptr::Ptr{SignatureStruct}
    if committer != nothing
        committer_ptr = convert(Ptr{SignatureStruct}, committer)
    else
        sig_ptr = Ptr{SignatureStruct}[0]
        @check ccall((:git_signature_default, libgit2), Cint,
                     (Ptr{Ptr{SignatureStruct}}, Ptr{Void}), sig_ptr, repo_ptr)
        committer_ptr = sig_ptr[1]

    end
    local author_ptr::Ptr{SignatureStruct}
    if author != nothing
        author_ptr = convert(Ptr{SignatureStruct}, author)
    else
        sig_ptr = Ptr{SignatureStruct}[0]
        @check ccall((:git_signature_default, libgit2), Cint,
                     (Ptr{Ptr{SignatureStruct}}, Ptr{Void}), sig_ptr, repo_ptr)
        author_ptr = sig_ptr[1]
    end
    tid = Oid(obj)
    nid_ptr = [Oid()]
    @check ccall((:git_note_create, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Void}, Ptr{SignatureStruct},
                  Ptr{SignatureStruct}, Ptr{Uint8}, Ptr{Oid}, Ptr{Uint8}, Cint),
                  nid_ptr, repo_ptr, committer_ptr, author_ptr, bref, &tid, msg, force)
    return nid_ptr[1]
end

function remove_note!(obj::GitObject;
                      committer::MaybeSignature=nothing,
                      author::MaybeSignature=nothing,
                      ref::MaybeString=nothing)
    repo_ptr  = ccall((:git_object_owner, libgit2), Ptr{Void}, (Ptr{Void},), obj)
    notes_ref = ref != nothing ? bytestring(ref) : bytestring("refs/notes/commits")
    local committer_ptr::Ptr{SignatureStruct}
    if committer != nothing
        committer_ptr = convert(Ptr{SignatureStruct}, committer)
    else
        sig_ptr = Ptr{SignatureStruct}[0]
        @check ccall((:git_signature_default, libgit2), Cint,
                     (Ptr{Ptr{SignatureStruct}}, Ptr{Void}), sig_ptr, repo_ptr)
        committer_ptr = sig_ptr[1]
    end
    local author_ptr::Ptr{SignatureStruct}
    if author != nothing
        author_ptr = convert(Ptr{SignatureStruct}, committer)
    else
        sig_ptr = Ptr{SignatureStruct}[0]
        @check ccall((:git_signature_default, libgit2), Cint,
                     (Ptr{Ptr{SignatureStruct}}, Ptr{Void}), sig_ptr, repo_ptr)
        author_ptr = sig_ptr[1]
    end
    tid = Oid(obj)
    err = ccall((:git_note_remove, libgit2), Cint,
                (Ptr{Void}, Ptr{Uint8},
                 Ptr{SignatureStruct}, Ptr{SignatureStruct}, Ptr{Oid}),
                 repo_ptr, notes_ref, author_ptr, committer_ptr, &tid)
    if err == GitErrorConst.ENOTFOUND
        return false
    elseif err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return true
end

function note_default_ref(r::GitRepo)
    refname_ptr = Ptr{Uint8}[0]
    @check ccall((:git_note_default_ref, libgit2), Cint,
                 (Ptr{Ptr{Uint8}}, Ptr{Void}), refname_ptr, r)
    return utf8(bytestring(refname_ptr[1]))
end

type NoteIterator
    repo::GitRepo
    ptr::Ptr{Void}
    notes_ref::MaybeString

    function NoteIterator(r::GitRepo, ptr::Ptr{Void}, notes_ref::MaybeString=nothing)
        @assert ptr != C_NULL
        it = new(r, ptr, notes_ref)
        finalizer(it, free!)
        return it
    end
end

free!(it::NoteIterator) = begin
    if it.ptr != C_NULL
        ccall((:git_note_iterator_free, libgit2), Void, (Ptr{Void},), it.ptr)
        it.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, it::NoteIterator) = it.ptr

function foreach(::Type{GitNote}, r::GitRepo, notes_ref::MaybeString=nothing)
    iter_ptr = Ptr{Void}[0]
    @check ccall((:git_note_iterator_new, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), iter_ptr, r, notes_ref)
    return NoteIterator(r, iter_ptr[1], notes_ref)
end

Base.start(it::NoteIterator) = begin
    note_id_ptr, ann_id_ptr = [Oid()], [Oid()]
    err = ccall((:git_note_next, libgit2), Cint,
                (Ptr{Oid}, Ptr{Oid}, Ptr{Void}), note_id_ptr, ann_id_ptr, it)
    if err == GitErrorConst.ITEROVER
        return nothing
    elseif err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    note_ptr = Ptr{Void}[0]
    err = ccall((:git_note_read, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Oid}),
                 note_ptr, it.repo, it.notes_ref, ann_id_ptr)
    if err != GitErrorConst.GIT_OK
        if note_ptr[1] != C_NULL
            ccall((:git_note_free, libgit2), Void, (Ptr{Void},), note_ptr[1])
        end
        throw(LibGitError(err))
    end
    n = GitNote(note_ptr[1])
    ccall((:git_note_free, libgit2), Void, (Ptr{Void},), note_ptr[1])
    return (n, ann_id_ptr[1])
end

Base.done(it::NoteIterator, state) = is(state, nothing)

Base.next(it::NoteIterator, state) = begin
    note_id_ptr, ann_id_ptr = [Oid()], [Oid()]
    err = ccall((:git_note_next, libgit2), Cint,
                (Ptr{Oid}, Ptr{Oid}, Ptr{Void}), note_id_ptr, ann_id_ptr, it)
    if err == GitErrorConst.ITEROVER
        return (state, nothing)
    elseif err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    note_ptr = Ptr{Void}[0]
    err = ccall((:git_note_read, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Oid}),
                 note_ptr, it.repo, C_NULL, note_id_ptr)
    if err != GitErrorConst.GIT_OK
        if note_ptr[1] != C_NULL
            ccall((:git_note_free, libgit2), Void, (Ptr{Void},), note_ptr[1])
        end
        throw(LibGitError(err))
    end
    n = GitNote(note_ptr[1])
    ccall((:git_note_free, libgit2), Void, (Ptr{Void},), note_ptr[1])
    return (state, (n, ann_id_ptr[1]))
end

function ahead_behind(r::GitRepo, lcommit::GitCommit, ucommit::GitCommit)
    return ahead_behind(r, Oid(lcommit), Oid(ucommit))
end

function ahead_behind(r::GitRepo, lid::Oid, uid::Oid)
    ahead, behind = Csize_t[0], Csize_t[0]
    @check ccall((:git_graph_ahead_behind, libgit2), Cint,
                 (Ptr{Csize_t}, Ptr{Csize_t}, Ptr{Void}, Ptr{Oid}, Ptr{Oid}),
                 ahead, behind, r, &lid, &uid)
    return (int(ahead[1]), int(behind[1]))
end

is_descendant_of(r::GitRepo, prev::GitCommit, ances::GitCommit) =
    is_descendant_of(r, Oid(prev), Oid(ances))

function is_descendant_of(r::GitRepo, prev::Oid, ances::Oid)
    if !isa(lookup(GitCommit, repo, prev), GitCommit)
        throw(ArgumentError("prev $prev is not a valid commit id"))
    end
    if !isa(lookup(GitCommit, repo, ances), GitCommit)
        throw(ArgumentError("ances $ances is not a valid commit id"))
    end
    return bool(ccall((:git_graph_descendant_of, libgit2), Cint,
                      (Ptr{Void}, Ptr{Oid}, Ptr{Oid}), r, &prev, &ances))
end

function blob_at(r::GitRepo, rev::Oid, pth::String)
    tree = GitTree(lookup_commit(r, rev))
    local blob_entry::GitTreeEntry
    try
        blob_entry = entry_bypath(tree, pth)
        @assert isa(blob_entry, GitTreeEntry{GitBlob})
    catch
        return nothing
    end
    blob = lookup_blob(r, Oid(blob_entry))
    return blob
end

#TODO: consolidate with odb
function write!{T<:GitObject}(::Type{T}, r::GitRepo, buf::ByteString)
    odb = Odb(r)
    stream_ptr = Ptr{Void}[0]
    @check ccall((:git_odb_open_wstream, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Csize_t, Cint),
                 stream_ptr, odb, length(buf), git_otype(T))
    @assert stream_ptr[1] != C_NULL
    err = ccall((:git_odb_stream_write, libgit2), Cint,
                (Ptr{Void}, Ptr{Uint8}, Csize_t), stream_ptr[1], buf, length(buf))
    id_ptr = [Oid()]
    if err == GitErrorConst.GIT_OK
        err = ccall((:git_odb_stream_finalize_write, libgit2), Cint,
                    (Ptr{Oid}, Ptr{Void}), id_ptr, stream_ptr[1])
    end
    ccall((:git_odb_stream_free, libgit2), Void, (Ptr{Void},), stream_ptr[1])
    if err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return id_ptr[1]
end


function repo_discover(pth::String="", acrossfs::Bool=true)
    isempty(pth) && (pth = pwd())
    brepo = zeros(Uint8, GitConst.GIT_PATH_MAX)
    buf_ptr = [BufferStruct()]
    @check ccall((:git_repository_discover, libgit2), Cint,
                 (Ptr{BufferStruct}, Ptr{Uint8}, Cint, Ptr{Uint8}),
                 buf_ptr, pth, acrossfs, C_NULL)
    bstr = bytestring(buf_ptr[1])
    ccall((:git_buf_free, libgit2), Void, (Ptr{BufferStruct},), buf_ptr)
    return GitRepo(bstr)
end

function revparse(r::GitRepo, rev::String)
    obj_ptr = Ptr{Void}[0]
    @check ccall((:git_revparse_single, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), obj_ptr, r, rev)
    return gitobj_from_ptr(obj_ptr[1])
end
revparse(r::GitRepo, rev::Oid) = revparse(r, string(rev))

function merge_base(r::GitRepo, args...)
    if length(args) < 2
        throw(ArgumentError("merge_base needs 2+ commits"))
    end
    arg_oids = vcat([raw(Oid(r, a)) for a in args]...)
    @assert length(arg_oids) == length(args) * OID_RAWSZ
    len = convert(Csize_t, length(args))
    id_ptr = [Oid()]
    err = ccall((:git_merge_base_many, libgit2), Cint,
                (Ptr{Oid}, Ptr{Void}, Csize_t, Ptr{Uint8}), id_ptr, r, len, arg_oids)
    if err == GitErrorConst.ENOTFOUND
        return nothing
    elseif err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return id_ptr[1]
end

revparse_oid(r::GitRepo, rev::Oid) = Oid(revparse(r, string(rev)))
revparse_oid(r::GitRepo, rev::String) = Oid(revparse(r, rev))

Odb(r::GitRepo) = begin
    odb_ptr = Ptr{Void}[0]
    @check ccall((:git_repository_odb, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}), odb_ptr, r)
    return Odb(odb_ptr[1])
end

function lookup{T<:GitObject}(::Type{T}, r::GitRepo, id::Oid)
    obj_ptr = Ptr{Void}[0]
    @check ccall((:git_object_lookup, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Oid}, Cint),
                 obj_ptr, r, &id, git_otype(T))
    return T(obj_ptr[1])
end

function lookup{T<:GitObject}(::Type{T}, r::GitRepo, oid::String)
    len = length(oid)
    id_ptr  = [Oid()]
    obj_ptr = Ptr{Void}[0]
    @check ccall((:git_oid_fromstrn, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Uint8}, Csize_t), id_ptr, oid, len)
    if len < OID_HEXSZ
        @check ccall((:git_object_lookup_prefix, libgit2), Cint,
                     (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Oid}, Csize_t, Cint),
                     obj_ptr, r, id_ptr, len, git_otype(T))
    else
        @check ccall((:git_object_lookup, libgit2), Cint,
                     (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Oid}, Cint),
                     obj_ptr, r, id_ptr, git_otype(T))
    end
    return T(obj_ptr[1])
end
lookup(r::GitRepo, id::Oid)    = lookup(GitAnyObject, r, id)
lookup(r::GitRepo, id::String) = lookup(GitAnyObject, r, id)

lookup_blob(r::GitRepo, id)   = lookup(GitBlob, r, id)
lookup_tree(r::GitRepo, id)   = lookup(GitTree, r, id)
lookup_commit(r::GitRepo, id) = lookup(GitCommit, r, id)

lookup(r::GitRepo, o::GitReference) = lookup(GitReference, r, o)

references(r::GitRepo, glob::String="") = collect(GitReference, foreach(GitReference, r, glob))

function lookup(::Type{GitReference}, r::GitRepo, name::String)
    ref_ptr = Ptr{Void}[0]
    err = ccall((:git_reference_lookup, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), ref_ptr, r, name)
    if err == GitErrorConst.ENOTFOUND
        return nothing
    elseif err != GitErrorConst.GIT_OK
        return LibGitError(err)
    end
    return GitReference(ref_ptr[1])
end
lookup(::Type{GitReference}, r::GitRepo, ref::GitReference{Oid}) = lookup(r, target(ref))

lookup_ref(r::GitRepo, name::String) = lookup(GitReference, r, name)
lookup_ref(r::GitRepo, ref::GitReference) = lookup(GitReference, r, ref)

function create_ref(r::GitRepo, refname::String, id::Oid;
                    force::Bool=false,
                    sig::Union(Nothing,Signature)=nothing,
                    logmsg::Union(Nothing,String)=nothing)
    ref_ptr = Ptr{Void}[0]
    @check ccall((:git_reference_create, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Oid},
                  Cint, Ptr{SignatureStruct}, Ptr{Uint8}),
                 ref_ptr, r, refname, &id, force,
                 sig != nothing ? sig : C_NULL,
                 logmsg != nothing ? logmsg : C_NULL)
    return GitReference(ref_ptr[1])
end

function create_ref(r::GitRepo, refname::String, target::String;
                    force::Bool=false, sig=nothing, logmsg=nothing)
    create_sym_ref(r, refname, target; force=force, sig=sig, logmsg=logmsg)
end

function create_sym_ref(r::GitRepo, refname::String, target::String;
                        force::Bool=false, sig=nothing, logmsg=nothing)
    ref_ptr = Ptr{Void}[0]
    @check ccall((:git_reference_symbolic_create, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Uint8},
                 Cint, Ptr{SignatureStruct}, Ptr{Uint8}),
                 ref_ptr, r, refname, target, force,
                 sig != nothing ? sig : C_NULL,
                 logmsg != nothing ? logmsg : C_NULL)
    return GitReference(ref_ptr[1])
end

function commit(r::GitRepo,
                refname::String,
                msg::String,
                author::Signature,
                committer::Signature,
                tree::GitTree,
                parents::GitCommit...)
    id_ptr = [Oid()]
    nparents = length(parents)
    parentptrs = Ptr{Void}[c.ptr for c in parents]
    @check ccall((:git_commit_create, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Void}, Ptr{Uint8},
                  Ptr{SignatureStruct}, Ptr{SignatureStruct},
                  Ptr{Uint8}, Ptr{Uint8}, Ptr{Void},
                  Csize_t, Ptr{Ptr{Void}}),
                 id_ptr, r, refname, author, committer, C_NULL, msg, tree,
                 nparents, nparents > 0 ? parentptrs : C_NULL)
    return id_ptr[1]
end

function commit(r::GitRepo,
                msg::String,
                author::Signature,
                committer::Signature)
    idx = GitIndex(r)
    id_ptr = [Oid()]
    @check ccall((:git_index_write_tree, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Void}), id_ptr, idx)
    tree = lookup(GitTree, r, id_ptr[1])
    parent = lookup(GitCommit, r, target(head(r)))
    return commit(r, "HEAD", msg, author, committer, tree, parent)
end

function reset!(r::GitRepo, obj::Union(GitCommit,GitTag), typ::Symbol;
                sig::MaybeSignature=nothing,
                logmsg::MaybeString=nothing)
    git_reset = typ === :soft ? 1 :
                typ === :mixed ? 2 :
                typ === :hard ? 3 :
                throw(ArgumentError("unknown reset type :$type"))
    @check ccall((:git_reset, libgit2), Cint,
                 (Ptr{Void}, Ptr{Void}, Cint, Ptr{Void}, Ptr{Uint8}),
                 r, obj, git_reset,
                 sig != nothing ? sig : C_NULL,
                 logmsg != nothing ? logmsg : C_NULL)
    return
end

function reset!(r::GitRepo, ref::String, typ::Symbol;
       sig::MaybeSignature=nothing,
       logmsg::MaybeString=nothing)
    reset!(r, revparse(r, ref), typ, sig=sig, logmsg=logmsg)
end

function set_workdir!(r::GitRepo, dir::String, update::Bool)
    @check ccall((:git_repository_set_workdir, libgit2), Cint,
                 (Ptr{Void}, Ptr{Uint8}, Cint), r, dir, update)
    return r
end
# branch type can be :local or :remote
function lookup(::Type{GitBranch}, r::GitRepo, branch_name::String, branch_type::Symbol=:local)
    git_branch_type = branch_type == :local  ? GitConst.BRANCH_LOCAL :
                      branch_type == :remote ? GitConst.BRANCH_REMOTE :
                      throw(ArgumentError("branch_type can be :local or :remote"))
    branch_ptr = Ptr{Void}[0]
    err = ccall((:git_branch_lookup, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Cint),
                branch_ptr, r, branch_name, git_branch_type)
    if err == GitErrorConst.GIT_OK
        return GitBranch(branch_ptr[1])
    elseif err == GitErrorConst.ENOTFOUND
        return nothing
    else
        throw(LibGitError(err))
    end
end

lookup_branch(r::GitRepo, branch_name::String, branch_type=:local) =
        lookup(GitBranch, r, branch_name, branch_type)

lookup_branch(r::GitRepo, branch_id::Oid, branch_type=:local) =
        lookup(GitBranch, r, string(branch_id), branch_type)

#TODO: give intelligent error msg when target does not exist
function create_branch(r::GitRepo, bname::String, target::Oid;
                       force::Bool=false,
                       sig::Union(Nothing,Signature)=nothing,
                       logmsg::Union(Nothing,String)=nothing)
    commit = lookup_commit(r, target)
    branch_ptr = Ptr{Void}[0]
    @check ccall((:git_branch_create, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Void},
                 Cint, Ptr{SignatureStruct}, Ptr{Uint8}),
                 branch_ptr, r, bname, commit, force,
                 sig != nothing ? sig : C_NULL,
                 logmsg != nothing ? logmsg : C_NULL)
    return GitBranch(branch_ptr[1])
end

function create_branch(r::GitRepo, n::String, target::String="HEAD";
                       force::Bool=false, sig=nothing, logmsg=nothing)
    id = revparse_oid(r, target)
    return create_branch(r, n, id, force=force, sig=sig, logmsg=logmsg)
end

function create_branch(r::GitRepo, n::String, target::GitCommit;
                       force::Bool=false, sig=nothing, logmsg=nothing)
    id = Oid(target)
    return create_branch(r, n, id, force=force, sig=sig, logmsg=logmsg)
end

type BranchIterator
    repo::GitRepo
    ptr::Ptr{Void}

    function BranchIterator(r::GitRepo, ptr::Ptr{Void})
        @assert ptr != C_NULL
        it = new(r, ptr)
        finalizer(it, free!)
        return it
    end
end

free!(it::BranchIterator) = begin
    if it.ptr != C_NULL
        ccall((:git_branch_iterator_free, libgit2), Void, (Ptr{Void},), it.ptr)
        it.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, b::BranchIterator) = b.ptr

function foreach(::Type{GitBranch}, r::GitRepo, filter::Symbol=:all)
    git_filter = filter === :all ? (GitConst.BRANCH_LOCAL | GitConst.BRANCH_REMOTE) :
                 filter == :local ? GitConst.BRANCH_LOCAL :
                 filter == :remote ? GitConst.BRANCH_REMOTE :
                 throw(ArgumentError("filter can be :all, :local, or :remote"))
    iter_ptr = Ptr{Void}[0]
    @check ccall((:git_branch_iterator_new, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Cint), iter_ptr, r, git_filter)
    return BranchIterator(r, iter_ptr[1])
end

Base.start(b::BranchIterator) = begin
    branch_ptr, branch_type = Ptr{Void}[0], Cint[0]
    err = ccall((:git_branch_next, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Cint}, Ptr{Void}), branch_ptr, branch_type, b)
    if err == GitErrorConst.ITEROVER
        return nothing
    elseif err != GitErrorConst.GIT_OK
        if branch_ptr[1] != C_NULL
            ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), branch_ptr[1])
        end
        throw(LibGitError(err))
    end
    return GitBranch(branch_ptr[1])
end

Base.done(it::BranchIterator, state) = is(state, nothing)

Base.next(it::BranchIterator, state) = begin
    branch_ptr, branch_type = Ptr{Void}[0], Cint[0]
    err = ccall((:git_branch_next, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Cint}, Ptr{Void}), branch_ptr, branch_type, it)
    if err == GitErrorConst.ITEROVER
        return (state, nothing)
    elseif err != GitErrorConst.GIT_OK
        if branch_ptr[1] != C_NULL
            ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), branch_ptr[1])
        end
        throw(LibGitError(err))
    end
    return (state, GitBranch(branch_ptr[1]))
end

branches(r::GitRepo, filter::Symbol=:all) = collect(GitBranch, foreach(GitBranch, r, filter))
branch_names(r::GitRepo, filter::Symbol=:all) = map(name, branches(r, filter))

#------- Tree merge ---------
parse_merge_options(opts::Nothing) = MergeTreeOptsStruct()

function parse_merge_options(opts::Dict)
    if isempty(opts)
        return MergeTreeOptsStruct()
    end
    local rename_threshold = zero(Cuint)
    if haskey(opts, :rename_threshold)
        rename_threshold = convert(Cuint, opts[:rename_threshold])
    end
    local target_limit = zero(Cuint)
    if haskey(opts, :target_limit)
        target_limit = convert(Cuint, opts[:target_limit])
    end
    local automerge_flags = zero(Cint)
    if haskey(opts, :automerge)
        a = opts[:automerge]
        if a === :normal
            automerge_flags = GitConst.MERGE_AUTOMERGE_NORMAL
        elseif a === :favor_ours
            automerge_flags = GitConst.MERGE_AUTOMERGE_FAVOR_OURS
        elseif a === :favor_theirs
            automerge_flags = GitConst.MERGE_AUTOMERGE_FAVOR_THEIRS
        elseif a === :union
            automerge_flags = GitConst.MERGE_AUTOMERGE_FAVOR_UNION
        else
            throw(ArgumentError("Unknown automerge option :$a"))
        end
    end
    local flags = zero(Cint)
    if get(opts, :renames, false)
        flags |= MERGE_TREE_FIND_RENAMES
    end
    return MergeTreeOptsStruct(one(Cint),
                               flags,
                               rename_threshold,
                               target_limit,
                               C_NULL,
                               automerge_flags)
end

immutable MergeResult
    status::Symbol
    commit::Oid
end

#=
merge_base(r::GitRepo, id1::Oid, id2::Oid) = begin
    out_id = [Oid()]
    @check ccall((:git_merge_base, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Void}, Ptr{Oid}, Ptr{Oid}),
                 id_ptr, r, id1, id2)
    return out_id[1]
end

merge_base(r::GitRepo, ids::Oid...) = begin
    in_ids = [ids...]
    out_id = [Oid()]
    @check ccall((:git_merge_base_many, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Void}, Csize_t, Ptr{Oid}),
                 out_id, r, length(in_ids), in_ids)
    return out_id[1]
end
=#

merge_analysis(r::GitRepo, their_commit::String) = begin
    commit = revparse(r, revparse)
    if !isa(commit, GitCommit)
        throw(ArgumentError("reference string must point to a valid git commit"))
    end
    return merge_analysis(r, commit)
end

merge_analysis(r::GitRepo, their_commit::GitReference) = begin
    commit = lookup(r, their_commit)
    if !isa(commit, GitCommit)
        throw(ArgumentError("GitReference must point to a valid git commit"))
    end
    return merge_analysis(r, commit)
end

merge_analysis(r::GitRepo, their_commit::Oid) = begin
    commit = lookup(r, their_commit)
    if !isa(commit, GitCommit)
        throw(ArgumentError("Oid must be a point to a valid git commit"))
    end
    return merge_analysis(r, commit)
end

merge_analysis(r::GitRepo, their_commit::GitCommit) = begin
    id = Oid(their_commit)
    mhead_ptr = Ptr{Void}[0]
    @check ccall((:git_merge_head_from_id, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Oid}),
                 mhead_ptr, r, &id)
    analysis_ptr, pref_ptr = Cint[0], Cint[0]
    @check ccall((:git_merge_analysis, libgit2), Cint,
                 (Ptr{Cint}, Ptr{Cint}, Ptr{Void},  Ptr{Ptr{Void}}, Csize_t),
                 analysis_ptr, pref_ptr, r, mhead_ptr, 1)
    ccall((:git_merge_head_free, libgit2), Void, (Ptr{Void},), mhead_ptr[1])
    res = Symbol[]
    analysis = analysis_ptr[1]
    if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_NORMAL)
        push!(res, :normal)
    end
    if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_UP_TO_DATE)
        push!(res, :uptodate)
    end
    if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_FASTFORWARD)
        push!(res, :fastforward)
    end
    if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_UNBORN)
        push!(res, :unborn)
    end
    pref = pref_ptr[1] == GitConst.GIT_MERGE_PREFERENCE_NONE ? :none :
           pref_ptr[1] == GitConst.GIT_MERGE_PREFERENCE_NO_FASTFORWARD ? :nofastforward :
           pref_ptr[1] == GitConst.GIT_MERGE_PREFERENCE_FASTFORWARD_ONLY ? :fastforwardonly :
           error("unknown merge analysis preference const $(pref_ptr[1])")
    return res, pref
end

merge_analysis(repo::GitRepo, mheads::Vector{Ptr{Void}}) = begin
    analysis_ptr = Cint[0]
    preference_ptr = Cint[0]
    @check ccall((:git_merge_analysis, libgit2), Cint,
                 (Ptr{Cint}, Ptr{Cint}, Ptr{Void}, Ptr{Ptr{Void}}, Csize_t),
                 analysis_ptr, preference_ptr, repo, mheads, length(mheads))
    return analysis_ptr[1], preference_ptr[1]
end

#TODO: tree's should reference owning repository
Base.merge!(r::GitRepo, t1::GitTree, t2::GitTree, opts=nothing) = begin
    gopts = parse_merge_options(opts)
    idx_ptr = Ptr{Void}[0]
    @check ccall((:git_merge_trees, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void},
                  Ptr{Void}, Ptr{Void}, Ptr{MergeTreeOptsStruct}),
                 idx_ptr, r, C_NULL, t1, t2, &gopts)
    return GitIndex(idx_ptr[1])
end

Base.merge!(r::GitRepo,
            t1::GitTree,
            t2::GitTree,
            ancestor::GitTree,
            opts::MaybeDict=nothing) = begin
    gopts = parse_merge_options(opts)
    idx_ptr = Ptr{Void}[0]
    @check ccall((:git_merge_trees, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void},
                 Ptr{Void}, Ptr{Void}, Ptr{MergeTreeOptsStruct}),
                 idx_ptr, r, ancestor.ptr, t1, t2, &gopts)
    return GitIndex(idx_ptr[1])
end

Base.merge!(r::GitRepo, b::String, opts=Dict()) = merge!(r, revparse(r, b), opts)
Base.merge!(r::GitRepo, id::Oid, opts=Dict()) = merge!(r, lookup(r, id), opts)

Base.merge!(r::GitRepo, c::GitCommit, opts=Dict()) = begin
    id = Oid(c)
    mhead_ptr = Ptr{Void}[0]
    @check ccall((:git_merge_head_from_id, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Oid}),
                 mhead_ptr, r, &id)
    try
        return _do_merge(r, mhead_ptr, #=sig,=# opts)
    finally
        if mhead_ptr[1] != C_NULL
            ccall((:git_merge_head_free, libgit2), Void, (Ptr{Void},), mhead_ptr[1])
        end
    end
end

Base.merge!(r::GitRepo, b::GitBranch, opts=Dict()) = begin
    ref = resolve(b)
    mhead_ptr = Ptr{Void}[0]
    @check ccall((:git_merge_head_from_ref, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void}), mhead_ptr, r, ref)
    try
        _do_merge(r, mhead_ptr, opts)
    finally
        if mhead_ptr[1] != C_NULL
            ccall((:git_merge_head_free, libgit2), Void, (Ptr{Void},), mhead_ptr[1])
        end
    end
end

function _do_merge(r::GitRepo, mhead_ptr::Vector{Ptr{Void}}, #=sig,=# opts=Dict())
    analysis_ptr, pref_ptr = Cint[0], Cint[0]
    @check ccall((:git_merge_analysis, libgit2), Cint,
                 (Ptr{Cint}, Ptr{Cint}, Ptr{Void},  Ptr{Ptr{Void}}, Csize_t),
                 analysis_ptr, pref_ptr, r, mhead_ptr, length(mhead_ptr))
    analysis, pref = analysis_ptr[1], pref_ptr[1]
    if isequal(analysis & GitConst.GIT_MERGE_ANALYSIS_UP_TO_DATE,
               GitConst.GIT_MERGE_ANALYSIS_UP_TO_DATE)
        return :uptodate, nothing
    end
    local ffstrategy::Symbol
    if haskey(opts, :ffstrategy) && opts[:ffstrategy] != :default
        ffstrategy = opts[:ffstrategy]
    else
        ffstrategy = pref == GitConst.GIT_MERGE_PREFERENCE_NONE ? :default :
                     pref == GitConst.GIT_MERGE_PREFERENCE_NO_FASTFORWARD ? :nofastforward :
                     pref == GitConst.GIT_MERGE_PREFERENCE_FASTFORWARD_ONLY ? :fastforwardonly :
                     error("unknown merge analysis preference const $(pref)")
    end
    if ffstrategy === :default
        if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_FASTFORWARD)
            merge_result = _fast_forward_merge(r, mhead_ptr[1], #=sig,=# opts)
        elseif bool(analysis & GitConst.GIT_MERGE_ANALYSIS_NORMAL)
            merge_result = _normal_merge(r, mhead_ptr, #=sig,=# opts)
        else
            error("unknown merge analysis strategy: $analysis")
        end
    elseif ffstrategy === :fastforwardonly
        if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_FASTFORWARD)
            merge_result = _fast_forward_merge(r, mhead_ptr[1], #=sig,=# opts)
        else
            error("cannot perform fast forward on a non fast forward merge")
        end
    elseif ffstrategy === :nofastforward
        if bool(analysis & GitConst.GIT_MERGE_ANALYSIS_NORMAL)
            merge_result = _normal_merge(r, mhead_ptr, #=sig,=# opts)
        else
            error("unknown merge analysis const $analysis")
        end
    else
        error("unknown fast forward strategy :$ffstrategy")
    end
    return merge_result
end

# perform a normal merge
_normal_merge(r::GitRepo, mhead_ptr::Vector{Ptr{Void}}, opts=Dict()) = begin
    mopts = parse_merge_options(opts)
    copts = parse_checkout_options(opts)
    @check ccall((:git_merge, libgit2), Cint,
                 (Ptr{Void}, Ptr{Ptr{Void}}, Csize_t,
                  Ptr{MergeTreeOptsStruct}, Ptr{CheckoutOptionsStruct}),
                  r, mhead_ptr, length(mhead_ptr), &mopts, &copts)
    free!(copts.paths)
    idx = GitIndex(r)
    if is_fully_merged(idx)
        if haskey(opts, :commit_on_success)
            msg = opts[:commit_on_success]
            if !isa(msg, String)
                throw(ArgumentError(":commit_on_success option value must be a string"))
            end
            # todo: Signature
            sig = default_signature(r)
            # commit the merge
            merge_commit = commit(r, msg, sig, sig)
            return (:nonfastforward, merge_commit)
        else
            return (:nonfastforward, nothing)
        end
    else
        return (:conflicts, nothing)
    end
end

_fast_forward_merge(r::GitRepo, mhead::Ptr{Void}, opts=Dict()) = begin
    id = Oid(ccall((:git_merge_head_id, libgit2), Ptr{Oid}, (Ptr{Void},), mhead))
    ffcommit = lookup(r, id)
    @assert ffcommit != nothing
    opts[:strategy] = :safe

    checkout_tree!(r, GitTree(ffcommit), opts)
    ref = resolve(head(r))
    if ref === nothing
        # reference does not exist, create it :TODO sig
        create_ref(r, "HEAD", id, force=true)
    else
        # update target reference
        set_target(head(r), id)
    end
    return (:fastforward, ffcommit)
end

#------- Merge Commits -----
function merge_commits(r::GitRepo,
                       ours::Union(GitCommit, Oid),
                       theirs::Union(GitCommit, Oid),
                       opts::MaybeDict=nothing)
    gopts = parse_merge_options(opts)
    isa(ours,   Oid) && (ours   = lookup_commit(r, ours))
    isa(theirs, Oid) && (theirs = lookup_commit(r, theirs))
    index_ptr = Ptr{Void}[0]
    @check ccall((:git_merge_commits, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void},
                  Ptr{Void}, Ptr{MergeTreeOptsStruct}),
                 index_ptr, r, ours, theirs, &gopts)
    return GitIndex(index_ptr[1])
end

#------- Repo Checkout -------
function cb_checkout_progress(path_ptr::Ptr{Uint8},
                              completed_steps::Csize_t,
                              total_steps::Csize_t,
                              payload::Ptr{Void})
    callback = unsafe_pointer_to_objref(payload)::Function
    path = path_ptr != C_NULL ? bytestring(path_ptr) : nothing
    callback(path, completed_steps, total_steps)
    return
end

const c_cb_checkout_progress = cfunction(cb_checkout_progress, Void,
                                         (Ptr{Uint8}, Csize_t, Csize_t, Ptr{Void}))

function cb_checkout_notify(why::Cint,
                            path_ptr::Ptr{Uint8},
                            baseline::Ptr{DiffFileStruct},
                            target::Ptr{DiffFileStruct},
                            workdir::Ptr{DiffFileStruct},
                            payload::Ptr{Void})
    callback = unsafe_pointer_to_objref(payload)::Function
    path = path_ptr != C_NULL ? bytestring(path_ptr) : nothing
    local reason::Symbol
    if why == GitConst.CHECKOUT_NOTIFY_CONFLICT
        reason = :conflict
    elseif why == GitConst.CHECKOUT_NOTIFY_DIRTY
        reason = :dirty
    elseif why == GitConst.CHECKOUT_NOTIFY_UPDATED
        reason = :updated
    elseif why == GitConst.CHECKOUT_NOTIFY_UNTRACKED
        reason = :untracked
    elseif why == GitConst.CHECKOUT_NOTIFY_IGNORED
        reason = :ignored
    else
        reason = :unknown
    end
    try
        callback(why, path, DiffFile(baseline), DiffFile(target), DiffFile(workdir))
        return GitErrorConst.GIT_OK
    catch
        return GitErrorConst.ERROR
    end
end

const c_cb_checkout_notify = cfunction(cb_checkout_notify, Cint,
                                       (Cint,
                                        Ptr{Uint8},
                                        Ptr{DiffFileStruct},
                                        Ptr{DiffFileStruct},
                                        Ptr{DiffFileStruct},
                                        Ptr{Void}))

parse_checkout_options(opts::Nothing) = CheckoutOptionsStruct()
parse_checkout_options(opts::Dict) = begin
    isempty(opts) && return CheckoutOptionsStruct()
    progress_cb = convert(Ptr{Void}, C_NULL)
    progress_payload = convert(Ptr{Void}, C_NULL)
    if haskey(opts, :progress)
        if !isa(opts[:progress], Function)
            throw(ArgumentError("checkout options :progress flag must be a Function"))
        end
        progress_cb = c_cb_checkout_progress
        progress_payload = pointer_from_objref(opts[:progress])
    end
    notify_cb = convert(Ptr{Void}, C_NULL)
    notify_payload = convert(Ptr{Void}, C_NULL)
    if haskey(opts, :notify)
        if !isa(opts[:notify], Function)
            throw(ArgumentError("checkout options :notify flag must be a Function"))
        end
        notify_cb = c_cb_checkout_notify
        notify_payload = pointer_from_objref(opts[:notify])
    end
    checkout_strategy = zero(Cuint)
    if haskey(opts, :strategy)
        local strategy::Vector{Symbol}
        if isa(opts[:strategy], Symbol)
            strategy = [opts[:strategy]]
        else
            strategy = opts[:strategy]
        end
        for s in strategy
            if s == :safe
                checkout_strategy |= GitConst.CHECKOUT_SAFE
            elseif s == :safe_create
                checkout_strategy |= GitConst.CHECKOUT_SAFE_CREATE
            elseif s == :force
                checkout_strategy |= GitConst.CHECKOUT_FORCE
            elseif s == :allow_conflicts
                checkout_strategy |= GitConst.CHECKOUT_ALLOW_CONFLICTS
            elseif s == :remove_untracked
                checkout_strategy |= GitConst.CHECKOUT_REMOVE_UNTRACKED
            elseif s == :remove_ignored
                checkout_strategy |= GitConst.CHECKOUT_REMOVE_IGNORED
            elseif s == :update_only
                checkout_strategy |= GitConst.CHECKOUT_UPDATE_ONLY
            elseif s == :dont_update_index
                checkout_strategy |= GitConst.CHECKOUT_DONT_UPDATE_INDEX
            elseif s == :no_refresh
                checkout_strategy |= GitConst.CHECKOUT_NO_REFRESH
            elseif s == :disable_pathspec_match
                checkout_strategy |= GitConst.CHECKOUT_DISABLE_PATHSPEC_MATCH
            elseif s == :skip_locked_directories
                checkout_strategy |= GitConst.CHECKOUT_SKIP_LOCKED_DIRECTORIES
            elseif s == :skip_unmerged
                checkout_strategy |= GitConst.CHECKOUT_SKIP_UNMERGED
            elseif s == :use_ours
                checkout_strategy |= GitConst.CHECKOUT_USE_OURS
            elseif s == :use_theirs
                checkout_strategy |= GitConst.CHECKOUT_USE_THEIRS
            elseif s == :update_submodules
                checkout_strategy |= GitConst.CHECKOUT_UPDATE_SUBMODULES
            elseif s == :update_submodules_if_changed
                checkout_strategy |= GitConst.CHECKOUT_UPDATE_SUBMODULES_IF_CHANGED
            else
                throw(ArgumentError("unknown checkout options :strategy flag :$s"))
            end
        end
    end
    notify_flags = zero(Cuint)
    if haskey(opts, :notify_flags)
        local flags::Vector{Symbol}
        if isa(opts[:notify_flags], Symbol)
            flags = [opts[:notify_flags]]
        else
            flags = opts[:notify_flags]
        end
        for f in flags
            if f == :conflict
                notify_flags |= GitConst.CHECKOUT_NOTIFY_CONFLICT
            elseif f == :dirty
                notify_flags |= GitConst.CHECKOUT_NOTIFY_DIRTY
            elseif f == :updated
                notify_flags |= GitConst.CHECKOUT_NOTIFY_UPDATED
            elseif f == :untracked
                notify_flags |= GitConst.CHECKOUT_NOTIFY_UNTRACKED
            elseif f == :ignored
                notify_flags |= GitConst.CHECKOUT_NOTIFY_IGNORED
            elseif f == :all
                notify_flags |= GitConst.CHECKOUT_NOTIFY_ALL
            else
                throw(ArgumentError("unknown checkout options :notify flag :$f"))
            end
        end
    end

    disable_filters = convert(Cint, bool(get(opts, :disable_filters, false)))

    dir_mode = zero(Cuint)
    if haskey(opts, :dir_mode)
        dir_mode = convert(Cuint, opts[:dir_mode])
    end
    file_mode = zero(Cuint)
    if haskey(opts, :file_mode)
        file_mode = convert(Cuint, opts[:file_mode])
    end
    file_open_flags = zero(Cint)
    if haskey(opts, :file_open_flags)
        file_open_flags = convert(Cint, opts[:file_open_flags])
    end
    target_directory = zero(Ptr{Uint8})
    if haskey(opts, :target_directory)
        if !isa(opts[:target_directory], String)
            throw(ArgumentError("checkout options :target_target must be a String"))
        end
        target_directory = convert(Ptr{Uint8}, bytestring(opts[:target_directory]))
    end
    baseline = zero(Ptr{Void})
    if haskey(opts, :baseline)
        if isa(opts[:baseline], GitTree)
            baseline = convert(Ptr{Void}, opts[:baseline])
        else
            throw(ArgumentError("checkout options :baseline must be a GitTree"))
        end
    end
    paths = StrArrayStruct()
    if haskey(opts, :paths)
        paths = StrArrayStruct(opts[:paths])
    end
    ancestor_label = zero(Ptr{Uint8})
    if haskey(opts, :ancestor_label)
        if !isa(opts[:ancestor_label], String)
            throw(ArgumentError("checkout options :ancestor_label must be a String"))
        end
        ancestor_label = convert(Ptr{Uint8}, opts[:ancestor_label])
    end
    our_label = zero(Ptr{Uint8})
    if haskey(opts, :our_label)
        if !isa(opts[:ancestor_label], String)
            throw(ArgumentError("checkout options :our_label must be a String"))
        end
        our_label = convert(Ptr{Uint8}, opts[:our_label])
    end
    their_label = zero(Ptr{Uint8})
    if haskey(opts, :their_label)
        if !isa(opts[:ancestor_label], String)
            throw(ArgumentError("checkout options :their_label must be a String"))
        end
        their_label = convert(Ptr{Uint8}, opts[:their_label])
    end
    return CheckoutOptionsStruct(
                          one(Cuint),
                          checkout_strategy,
                          disable_filters,
                          dir_mode,
                          file_mode,
                          file_open_flags,
                          notify_flags,
                          notify_cb,
                          notify_payload,
                          progress_cb,
                          progress_payload,
                          paths,
                          baseline,
                          target_directory,
                          ancestor_label,
                          our_label,
                          their_label)
end

typealias Treeish Union(GitCommit, GitTag, GitTree)

function remove_untracked!(r::GitRepo)
    opts = {:strategy => [:remove_untracked, :allow_conflicts]}
    gopts = parse_checkout_options(opts)
    err = ccall((:git_checkout_index, libgit2), Cint,
                (Ptr{Void}, Ptr{Void}, Ptr{CheckoutOptionsStruct}),
                r, C_NULL, &gopts)
    free!(gopts.paths)
    if err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return r
end

checkout_tree!(r::GitRepo, tree::String, opts::MaybeDict=nothing) =
    return checkout_tree!(r, revparse(r, tree), opts)

function checkout_tree!(r::GitRepo, tree::Treeish, opts::MaybeDict=nothing)
    gopts = parse_checkout_options(opts)
    err = ccall((:git_checkout_tree, libgit2), Cint,
                (Ptr{Void}, Ptr{Void}, Ptr{CheckoutOptionsStruct}),
                r, tree, &gopts)
    free!(gopts.paths)
    if err != GitErrorConst.GIT_OK
        throw(LibGitError(err))
    end
    return r
end

function checkout_head!(r::GitRepo, opts::MaybeDict=nothing)
    gopts = parse_checkout_options(opts)
    err = ccall((:git_checkout_head, libgit2), Cint,
                (Ptr{Void}, Ptr{CheckoutOptionsStruct}),r, &gopts)
    free!(gopts.paths)
    if err != GitErrorConst.GIT_OK
        throw(GitError(err))
    end
    return r
end

function checkout!(r::GitRepo, target::GitCommit, opts::MaybeDict=nothing)
    prev_head = is_head_detached(r) ? tip(head(r)) : name(head(r))
    create_ref(r, "HEAD", Oid(target), force=true)
    checkout_tree!(r, target, opts)
end

checkout!(target::GitBranch, opts=Dict()) = checkout!(owner(target), target, opts)

function checkout!(r::GitRepo, target, opts=Dict())
    delete!(opts, :paths)
    !haskey(opts, :strategy) && (opts[:strategy] = :safe)
    if target == "HEAD"
        return checkout_head!(r, opts)
    end
    local branch
    if isa(target, GitBranch)
        branch = target
    else
        branch = lookup_branch(r, string(target), :local)
        if branch == nothing
            branch = lookup_branch(r, string(target), :remote)
        end
    end
    if branch != nothing
        checkout_tree!(r, tip(branch), opts)
        isremote(branch) ? create_ref(r, "HEAD", Oid(tip(branch)), force=true) :
                           create_ref(r, "HEAD", canonical_name(branch), force=true)
    else
        commit = lookup_commit(r, revparse_oid(r, target))
        create_ref(r, "HEAD", Oid(commit), force=true)
        checkout_tree!(r, commit, opts)
    end
end

#------- Repo Clone -------
function cb_remote_transfer(stats_ptr::Ptr{TransferProgressStruct},
                            payload_ptr::Ptr{Void})
    stats = unsafe_load(stats_ptr)::TransferProgressStruct
    payload  = unsafe_pointer_to_objref(payload_ptr)::Dict
    callback = payload[:callbacks][:transfer_progress]
    try
        callback(stats.total_objects,
                 stats.indexed_objects,
                 stats.received_objects,
                 stats.received_bytes)
        return GitErrorConst.GIT_OK
    catch ex
        payload[:exception] = ex
        return GitErrorConst.ERROR
    end
end

const c_cb_remote_transfer = cfunction(cb_remote_transfer, Cint,
                                       (Ptr{TransferProgressStruct}, Ptr{Void}))

function extract_cred!(cred::GitCredential, cred_ptr::Ptr{Ptr{Void}}, allowed_types::Cuint)
    if isa(cred, PlainTextCred)
        if !bool(allowed_types & GitConst.CREDTYPE_USERPASS_PLAINTEXT)
            error("invalid credential type")
        end
        @check ccall((:git_cred_userpass_plaintext_new, libgit2), Cint,
                      (Ptr{Ptr{Void}}, Ptr{Uint8}, Ptr{Uint8}),
                       cred_ptr, cred.username, cred.password)
    elseif isa(cred, SSHKeyCred)
        if !bool(allowed_types & GitConst.CREDTYPE_SSH_KEY)
            error("invalid credential type")
        end
        @check ccall((:git_cred_ssh_key_new, libgit2), Cint,
                     (Ptr{Ptr{Void}}, Ptr{Uint8}, Ptr{Uint8}, Ptr{Uint8}, Ptr{Uint8}),
                     cred_ptr,
                     cred.username   != nothing ? cred.username   : C_NULL,
                     cred.publickey  != nothing ? cred.publickey  : C_NULL,
                     cred.privatekey != nothing ? cred.privatekey : C_NULL,
                     cred.passphrase != nothing ? cred.passphrase : C_NULL)
    elseif (cred, DefaultCred)
        if !bool(allowed_types & GitConst.CREDTYPE_SSH_KEY)
            error("invalid credential type")
        end
        @check ccall((:git_cred_default_new, libgit2), Cint, (Ptr{Ptr{Void}},), cred_ptr)
    else
        error("invalid credential type")
    end
    return
end

function cb_default_remote_credentials(cred_ptr::Ptr{Ptr{Void}},
                                       url::Ptr{Uint8},
                                       username_from_url::Ptr{Uint8},
                                       allowed_types::Cuint,
                                       payload_ptr::Ptr{Void})
    payload = unsafe_pointer_to_objref(payload_ptr)::Dict
    cred = payload[:credentials]
    try
        extract_cred!(cred, cred_ptr, allowed_types)
        return GitErrorConst.GIT_OK
    catch ex
        payload[:exception] = ex
        return GitErrorConst.ERROR
    end
end

const c_cb_default_remote_credentials =
    cfunction(cb_default_remote_credentials, Cint,
             (Ptr{Ptr{Void}}, Ptr{Uint8}, Ptr{Uint8}, Cuint, Ptr{Void}))

function cb_remote_credentials(cred_ptr::Ptr{Ptr{Void}},
                               url::Ptr{Uint8},
                               username::Ptr{Uint8},
                               allowed_types::Cuint,
                               payload_ptr::Ptr{Void})
    payload = unsafe_pointer_to_objref(payload_ptr)::Dict
    cred_func = payload[:credentials]::Function
    types = Symbol[]
    if bool(allowed_types & GitConst.CREDTYPE_USERPASS_PLAINTEXT)
        push!(types, :plaintext)
    end
    if bool(allowed_types & GitConst.CREDTYPE_SSH_KEY)
        push!(types, :sshkey)
    end
    if bool(allowed_types & GitConst.CREDTYPE_DEFAULT)
        push!(types, :default)
    end
    try
        cred = cred_func(url != C_NULL ? bytestring(url) : nothing,
                         username != C_NULL ? bytestring(username) : nothing,
                         types)
        @assert cred <: GitCredential
        extract_cred!(cred, cred_ptr, allowed_types)
        return GitErrorConst.GIT_OK
    catch err
        payload[:exception] = err
        return GitErrorConst.ERROR
    end
end

const c_cb_remote_credential = cfunction(cb_remote_credentials, Cint,
                                         (Ptr{Ptr{Void}}, Ptr{Uint8}, Ptr{Uint8}, Cuint, Ptr{Void}))

parse_clone_options(opts::Nothing, payload::Dict) = CloneOptionsStruct()
parse_clone_options(opts, payload::Dict) = begin
    isempty(opts) && return CloneOptionsStruct()
    local bare = zero(Cint)
    if haskey(opts, :bare)
        bare = convert(Cint, bool(opts[:bare]))
    end
    local remote_credentials_cb = zero(Ptr{Void})
    if haskey(opts, :credentials)
        cred = opts[:credentials]
        if isa(cred, GitCredential)
            payload[:credentials] = cred
            remote_credentials_cb = convert(Ptr{Void}, c_cb_default_remote_credentials)
        elseif isa(cred, Function)
            payload[:credentials] = cred
            remote_credentials_cb = convert(Ptr{Void}, c_cb_remote_credential)
        else
            throw(ArgumentError("clone option :credentials must be a GitCredential or Function type"))
        end
    end
    local remote_transfer_progress_cb = zero(Ptr{Void})
    if haskey(opts, :callbacks)
        callbacks = opts[:callbacks]
        if haskey(callbacks, :transfer_progress)
            if !isa(callbacks[:transfer_progress], Function)
                throw(ArgumentError("clone callback :transfer_progress must be a Function"))
            end
            payload[:callbacks] = callbacks
            remote_transfer_progress_cb = convert(Ptr{Void}, c_cb_remote_transfer)
        end
    end
    remote_payload  = convert(Ptr{Void}, pointer_from_objref(payload))
    checkout_stuct  = parse_checkout_options(opts)
    remotecb_struct = RemoteCallbacksStruct(one(Cuint),
                                            zero(Ptr{Void}),
                                            zero(Ptr{Void}),
                                            remote_credentials_cb,
                                            remote_transfer_progress_cb,
                                            zero(Ptr{Void}),
                                            remote_payload)
    return CloneOptionsStruct(one(Cuint),
                              checkout_stuct,
                              remotecb_struct,
                              bare,
                              zero(Cint),
                              zero(Cint),
                              zero(Ptr{Uint8}),
                              zero(Ptr{Uint8}),
                              zero(Ptr{SignatureStruct}))
end

function cb_remote_transfer(stats_ptr::Ptr{TransferProgressStruct}, payload_ptr::Ptr{Void})
    stats = unsafe_load(stats_ptr)::TransferProgressStruct
    payload  = unsafe_pointer_to_objref(payload_ptr)::Dict
    callback = payload[:callbacks][:transfer_progress]
    try
        callback(stats.total_objects,
                 stats.indexed_objects,
                 stats.received_objects,
                 stats.local_objects,
                 stats.total_deltas,
                 stats.indexed_deltas,
                 stats.received_bytes)
        return GitErrorConst.GIT_OK
    catch err
        payload[:exception] = err
        return GitErrorConst.ERROR
    end
end

function repo_clone(url::String, localpath::String, opts::MaybeDict=nothing)
    check_valid_url(url)
    payload = Dict()
    opts_struct = parse_clone_options(opts, payload)::CloneOptionsStruct
    repo_ptr = Ptr{Void}[0]
    err = ccall((:git_clone, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Uint8}, Ptr{Uint8}, Ptr{CloneOptionsStruct}),
                repo_ptr, url, localpath, &opts_struct)
    if haskey(payload, :exception)
        #TODO: clean up clone options struct
        throw(payload[:exception])
    end
    if err != GitErrorConst.GIT_OK
        #TODO: clean up clone options struct
        throw(LibGitError(err))
    end
    return GitRepo(repo_ptr[1])
end

#-------- Reference Iterator --------
#TODO: handle error's when iterating (see branch)
type ReferenceIterator
    repo::GitRepo
    ptr::Ptr{Void}

    function ReferenceIterator(r::GitRepo, ptr::Ptr{Void})
        @assert ptr != C_NULL
        it = new(r, ptr)
        finalizer(it, free!)
        return it
    end
end

free!(it::ReferenceIterator) = begin
    if it.ptr != C_NULL
        ccall((:git_reference_iterator_free, libgit2), Void, (Ptr{Void},), it.ptr)
        it.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, it::ReferenceIterator) = it.ptr

function foreach(::Type{GitReference}, r::GitRepo, glob::String="")
    iter_ptr = Ptr{Void}[0]
    if isempty(glob)
        @check ccall((:git_reference_iterator_new, libgit2), Cint,
                     (Ptr{Ptr{Void}}, Ptr{Void}), iter_ptr, r)
    else
        @check ccall((:git_reference_iterator_glob_new, libgit2), Cint,
                     (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), iter_ptr, r, glob)
    end
    return ReferenceIterator(r, iter_ptr[1])
end

Base.start(it::ReferenceIterator) = begin
    ref_ptr = Ptr{Void}[0]
    err = ccall((:git_reference_next, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}), ref_ptr, it)
    if err == GitErrorConst.ITEROVER
        return nothing
    elseif err != GitErrorConst.GIT_OK
        if ref_ptr[1] != C_NULL
            ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), ref_ptr[1])
        end
        throw(LibGitError(err))
    end
    return GitReference(ref_ptr[1])
end

Base.done(it::ReferenceIterator, state) = is(state, nothing)

Base.next(it::ReferenceIterator, state) = begin
    ref_ptr = Ptr{Void}[0]
    err = ccall((:git_reference_next, libgit2), Cint,
                (Ptr{Ptr{Void}}, Ptr{Void}), ref_ptr, it)
    if err == GitErrorConst.ITEROVER
        return (state, nothing)
    elseif err != GitErrorConst.GIT_OK
        if ref_ptr[1] != C_NULL
            ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), ref_ptr[1])
        end
        throw(LibGitError(err))
    end
    return (state, GitReference(ref_ptr[1]))
end
ref_names(r::GitRepo, glob::String="") = map(name, foreach(GitReference, r, glob))
