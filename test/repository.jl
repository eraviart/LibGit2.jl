# create bare repo
test_repo_path = joinpath(pwd(), "TestLibGit2")

function cleanup_repo(path)
    p = abspath(path)
    if isdir(p)
        run(`rm -f -R $p`)
    end
end

function tmp_repo(body, tmp_path)
   cleanup_repo(tmp_path)
   try
        body()
   catch err
       cleanup_repo(tmp_path)
       rethrow(err)
   end
   cleanup_repo(tmp_path)
end

# ------------------------------------
# Tests adapted from Git2Go Library
# ------------------------------------

# test creating bare repository
tmp_repo(test_repo_path) do
    repo_init(test_repo_path; bare=true)
    let repo = Repository(test_repo_path)
        @test isa(repo, Repository)
        @test repo_isbare(repo)
        @test repo_isempty(repo)
    end
end

# test creating repository
tmp_repo(test_repo_path) do
    repo_init(test_repo_path)
    let repo = Repository(test_repo_path)
        @test isa(repo, Repository)
        @test !(repo_isbare(repo))
        @test repo_isempty(repo)
        @test repo_workdir(repo) == abspath(test_repo_path)
        @test repo_path(repo) == joinpath(test_repo_path, ".git")
        @test isa(repo_index(repo), Index)
        # empty repo has no head
        @test head(repo) == nothing
        # empty repo has no tags
        @test tags(repo) == nothing
        # empty repo has no commits
        @test commits(repo) == nothing
        # empty repo has no references
        @test references(repo) == nothing
        
        @test isa(config(repo), GitConfig)
        @test isa(repo_treebuilder(repo), TreeBuilder)
    end
end

# -----------------------------------------
# Tests adapted from Ruby's Rugged Library
# -----------------------------------------
# test fails to open repos that don't exist
@sandboxed_test "testrepo.git" begin
    @test_throws Repository("fakepath/123")
    @test_throws Repository("test")
end
   
# can check if objects exist 
@sandboxed_test "testrepo.git" begin
    @test Oid("8496071c1b46c854b31185ea97743be6a8774479") in test_repo
    @test exists(test_repo, Oid("8496071c1b46c854b31185ea97743be6a8774479"))
    @test Oid("1385f264afb75a56a5bec74243be9b367ba4ca08") in test_repo
    @test exists(test_repo, Oid("1385f264afb75a56a5bec74243be9b367ba4ca08"))
    @test !(Oid("ce08fe4884650f067bd5703b6a59a8b3b3c99a09") in test_repo)
    @test !(exists(test_repo, Oid("ce08fe4884650f067bd5703b6a59a8b3b3c99a09")))
    @test !(Oid("8496071c1c46c854b31185ea97743be6a8774479") in test_repo)
    @test !(exists(test_repo, Oid("8496071c1c46c854b31185ea97743be6a8774479")))
end

# can read a raw object
@sandboxed_test "testrepo.git" begin
    rawobj = read(test_repo, Oid("8496071c1b46c854b31185ea97743be6a8774479"))
    @test match(r"tree 181037049a54a1eb5fab404658a3a250b44335d7", data(rawobj)) != nothing
    @test sizeof(rawobj) == 172
    @test isa(rawobj, OdbObject{GitCommit})
end

# can read object headers
@sandboxed_test "testrepo.git" begin
    h = read_header(test_repo, Oid("8496071c1b46c854b31185ea97743be6a8774479"))
    @test h[:type] == GitCommit
    @test h[:nbytes] == 172
end

# test check reads fail on missing objects
@sandboxed_test "testrepo.git" begin
    @test_throws read(Oid("a496071c1b46c854b31185ea97743be6a8774471"))
end

# test check read headers fail on missing objects
@sandboxed_test "testrepo.git" begin
    @test_throws read_header(Oid("a496071c1b46c854b31185ea97743be6a8774471"))
end

# test walking with block
@sandboxed_test "testrepo.git" begin
    oid = Oid("a4a7dce85cf63874e984719f4fdd239f5145052f")
    list = {}
    walk(test_repo, oid) do c
       push!(list, c)
    end
    @test join(map(c -> hex(c)[1:5], list), ".") == "a4a7d.c4780.9fd73.4a202.5b5b0.84960"
end

# test walking without block
@sandboxed_test "testrepo.git" begin
    oid = Oid("a4a7dce85cf63874e984719f4fdd239f5145052f")
    commits = walk(test_repo, oid)
    @test isa(commits, Task)
    @test istaskdone(commits) == false
end

# test lookup object
@sandboxed_test "testrepo.git" begin
    obj = lookup(test_repo, Oid("8496071c1b46c854b31185ea97743be6a8774479"))
    @test isa(obj, GitCommit)
end

# test find reference
@sandboxed_test "testrepo.git" begin
    ref = lookup_ref(test_repo, "refs/heads/master")
    @test isa(ref, GitReference)
    @test name(ref) == "refs/heads/master"
end

# match all refs
@sandboxed_test "testrepo.git" begin
    refs = collect(iter_refs(test_repo; glob="refs/heads/*"))
    @test length(refs) == 12
end

# return all ref names
@sandboxed_test "testrepo.git" begin
    rnames = ref_names(test_repo)
    @test length(rnames) == 21
end

# return all tags
@sandboxed_test "testrepo.git" begin
    ts = tags(test_repo)
    @test length(ts) == 7
end

# return all matching tags
@sandboxed_test "testrepo.git" begin
    @test length(tags(test_repo, "e90810b")) == 1
    @test length(tags(test_repo, "*tag*")) == 4
end

# return a list of all remotes
@sandboxed_test "testrepo.git" begin
    rs = remotes(test_repo)
    @test length(rs) == 5
end

# test_lookup_head
@sandboxed_test "testrepo.git" begin
    h = head(test_repo)
    @test isa(h, GitReference)
    @test name(h) == "refs/heads/master"
    @test target(h) == Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750")
    #@test isa( :direct
end

# test_set_head_ref
@sandboxed_test "testrepo.git" begin
    set_head!(test_repo, "refs/heads/packed")
    @test name(head(test_repo)) == "refs/heads/packed"
end

# test_set_head_invalid
@sandboxed_test "testrepo.git" begin
    @test_throws set_head!(test_repo, "a65fedf39aefe402d3bb6e24df4d4f5fe4547750")
end

# test_access_a_file
@sandboxed_test "testrepo.git" begin
#    id = Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750")
#    blob = blob_at(test_repo, id, 'new.txt')
#    @test "my new file\n" == content(blob)
end

# test_access_a_missing_file
@sandboxed_test "testrepo.git" begin
#    id = Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750")
#    blob = blob_at(test_repo, id, 'file-not-found.txt')
#    @test blob == nothing
end

# test_enumerate_all_objects
@sandboxed_test "testrepo.git" begin
#    @test count(x -> x, test_repo) == 1687
#    assert_equal 1687, @repo.each_id.count
end

# test_loading_alternates
@sandboxed_test "testrepo.git" begin
#    alt_path = joinpath(pwd(), 'fixtures/alternate/objects')
#    @assert isdir(alt_path)
#    repo = Rugged::Repository.new(@repo.path, :alternates => [alt_path])
#    begin
#      assert_equal 1690, repo.each_id.count
#      assert repo.read('146ae76773c91e3b1d00cf7a338ec55ae58297e2')
#    ensure
#      repo.close
#    end
end

# test_alternates_with_invalid_path_type
@sandboxed_test "testrepo.git" begin
#    assert_raises TypeError do
#      Rugged::Repository.new(@repo.path, :alternates => [:invalid_input])
#    end
end

# test_find_merge_base_between_oids
@sandboxed_test "testrepo.git" begin
#    commit1 = Oid("a4a7dce85cf63874e984719f4fdd239f5145052f")
#    commit2 = Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750")
#    base    = Oid("c47800c7266a2be04c571c04d5a6614691ea99bd")
#    @test base == merge_base(test_repo, commit1, commit2)
end

# test_find_merge_base_between_commits
@sandboxed_test "testrepo.git" begin
#    commit1 = lookup(test_repo, Oid("a4a7dce85cf63874e984719f4fdd239f5145052f"))
#    commit2 = lookup(test_repo, Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750"))
#    base    = Oid('c47800c7266a2be04c571c04d5a6614691ea99bd")
#    @test base == merge_base(test_repo, commit1, commit2)
end

# test_find_merge_base_between_ref_and_oid
@sandboxed_test "testrepo.git" begin
#    commit1 = "a4a7dce85cf63874e984719f4fdd239f5145052f"
#    commit2 = "refs/heads/master"
#    base    = Oid("c47800c7266a2be04c571c04d5a6614691ea99bd")
#    @test base == merge_base(test_repo, commit1, commit2)
end

# test_find_merge_base_between_many
@sandboxed_test "testrepo.git" begin
#    commit1 = Oid('a4a7dce85cf63874e984719f4fdd239f5145052f')
#    commit2 = "refs/heads/packed"
#    commit3 = lookup(test_repo, Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750"))
#
#    base    = Oid("c47800c7266a2be04c571c04d5a6614691ea99bd")
#    @test base == merge_base(test_repo, commit1, commit2, commit3)
end

# test_ahead_behind_with_oids
@sandboxed_test "testrepo.git" begin
    ahead, behind = ahead_behind(test_repo,
      Oid("a4a7dce85cf63874e984719f4fdd239f5145052f"),
      Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750")
    )
    @test ahead == 2 
    @test behind == 1
end

# test_ahead_behind_with_commits
@sandboxed_test "testrepo.git" begin
    ahead, behind = ahead_behind(test_repo, 
      lookup(test_repo, Oid("a4a7dce85cf63874e984719f4fdd239f5145052f")),
      lookup(test_repo, Oid("a65fedf39aefe402d3bb6e24df4d4f5fe4547750"))
    )
    @test ahead == 2 
    @test behind == 1
end
