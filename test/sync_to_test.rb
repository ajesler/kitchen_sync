require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

class SyncToTest < KitchenSync::EndpointTestCase
  include TestTableSchemas

  def from_or_to
    :to
  end

  def setup_with_footbl
    clear_schema
    create_footbl
    execute "INSERT INTO footbl VALUES (2, 10, 'test'), (4, NULL, 'foo'), (5, NULL, NULL), (8, -1, 'longer str'), (301, 0, NULL), (302, 0, NULL), (555, 0, NULL), (1000, 0, NULL), (1001, 0, 'last')"
    @rows = [[2,     10,       "test"],
             [4,    nil,        "foo"],
             [5,    nil,          nil],
             [8,     -1, "longer str"],
             [301,    0,          nil],
             [302,    0,          nil],
             [555,    0,          nil],
             [1000,   0,          nil],
             [1001,   0,       "last"]]
    @keys = @rows.collect {|row| [row[0]]}
  end

  test_each "it immediately requests the key range, and finishes without needing to make any changes if the table is empty at both ends" do
    clear_schema
    create_footbl

    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", [], []]
    expect_quit_and_close

    assert_equal [],
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "it immediately requests the key range, and clears the table if it is empty at the 'from' end but not the 'to' end" do
    clear_schema
    setup_with_footbl

    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", [], []]
    expect_quit_and_close

    assert_equal [],
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "it immediately requests the key range, and immediately asks for the rows if it is empty at the 'to' end but not the 'from' end" do
    clear_schema
    create_footbl

    @rows = [[2,     10,       "test"],
             [1000,   0,          nil],
             [1001,   0,       "last"]]

    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", [2], [1001]]
    expect_command Commands::ROWS,
                   ["footbl", [], [1001]]
    send_results   Commands::ROWS,
                   ["footbl", [], [1001]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "accepts matching hashes and asked for the hash of the next row(s), doubling the number of rows each time and starting from where the previous range ended" do
    setup_with_footbl

    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", @keys[0], @keys[8]]

    # the range will be initially subdivided into two around the middle of the key range
    expect_command Commands::HASH, ["footbl", [], @keys[6], 1]
    send_command   Commands::HASH, ["footbl", [], @keys[6], 1, 1, hash_of(@rows[0..0])]

    # carrying on with the second half of that first subdivision
    expect_command Commands::HASH, ["footbl", @keys[6], @keys[8], 1]
    send_command   Commands::HASH, ["footbl", @keys[6], @keys[8], 1, 1, hash_of(@rows[7..7])]

    # we'll subdivide the remaining part of that range again, and will process the subdivisions first
    # note that the subdivisions don't fall exactly halfway in the ranges, because the keys are not evenly distributed
    expect_command Commands::HASH, ["footbl", @keys[0], @keys[4], 2]
    send_command   Commands::HASH, ["footbl", @keys[0], @keys[4], 2, 2, hash_of(@rows[1..2])]
    expect_command Commands::HASH, ["footbl", @keys[4], @keys[6], 2]
    send_command   Commands::HASH, ["footbl", @keys[4], @keys[6], 2, 2, hash_of(@rows[5..6])]

    # this is the continuation of the second-to-last range; one more subdivision will have been attempted, but it
    # wouldn't have been able to as the keys are so unevenly spread that there were no rows after the midpoint
    expect_command Commands::HASH, ["footbl", @keys[2], @keys[4], 4]
    send_command   Commands::HASH, ["footbl", @keys[2], @keys[4], 4, 2, hash_of(@rows[3..4])]

    # and again the keys are such that we don't see a further subdivision, although it would have been attempted
    expect_command Commands::HASH, ["footbl", @keys[7], @keys[8], 2]
    send_command   Commands::HASH, ["footbl", @keys[7], @keys[8], 2, 1, hash_of(@rows[8..8])]

    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "requests and applies the row if we send a different hash for a single row, then moves onto the next row, resetting the number of rows to hash" do
    setup_with_footbl
    execute "UPDATE footbl SET col3 = 'different' WHERE col1 = 2 OR col1 = 4"

    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", @keys[0], @keys[-1]]
    expect_command Commands::HASH, ["footbl", [], @keys[6], 1]
    send_command   Commands::HASH, ["footbl", [], @keys[6], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["footbl", @keys[6], @keys[8], 1]
    send_command   Commands::HASH, ["footbl", @keys[6], @keys[8], 1, 1, hash_of(@rows[7..7])]
    expect_command Commands::ROWS,
                   ["footbl", [], @keys[0]]
    send_results   Commands::ROWS,
                   ["footbl", [], @keys[0]],
                   @rows[0]
    expect_command Commands::HASH, ["footbl", @keys[0], @keys[4], 1]
    send_command   Commands::HASH, ["footbl", @keys[0], @keys[4], 1, 1, hash_of(@rows[1..1])]
    expect_command Commands::HASH, ["footbl", @keys[4], @keys[6], 1]
    send_command   Commands::HASH, ["footbl", @keys[4], @keys[6], 1, 1, hash_of(@rows[5..5])]
    expect_command Commands::ROWS,
                   ["footbl", @keys[0], @keys[1]]
    send_results   Commands::ROWS,
                   ["footbl", @keys[0], @keys[1]],
                   @rows[1]
    expect_command Commands::HASH, ["footbl", @keys[1], @keys[4], 1]
    send_command   Commands::HASH, ["footbl", @keys[1], @keys[4], 1, 1, hash_of(@rows[2..2])]
    expect_command Commands::HASH, ["footbl", @keys[5], @keys[6], 2]
    send_command   Commands::HASH, ["footbl", @keys[5], @keys[6], 2, 1, hash_of(@rows[6..6])]
    expect_command Commands::HASH, ["footbl", @keys[2], @keys[4], 2]
    send_command   Commands::HASH, ["footbl", @keys[2], @keys[4], 2, 2, hash_of(@rows[3..4])]
    expect_command Commands::HASH, ["footbl", @keys[7], @keys[8], 2]
    send_command   Commands::HASH, ["footbl", @keys[7], @keys[8], 2, 1, hash_of(@rows[8..8])]
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "reduces the search range and tries again if we send a different hash for multiple rows" do
    setup_with_footbl
    execute "UPDATE footbl SET col3 = 'different' WHERE col1 = 301"

    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", @keys[0], @keys[8]]

    expect_command Commands::HASH, ["footbl", [], @keys[6], 1]
    send_command   Commands::HASH, ["footbl", [], @keys[6], 1, 1, hash_of(@rows[0..0])]

    # second half of the initial subdivision, which we'll come back to later
    expect_command Commands::HASH, ["footbl", @keys[6], @keys[8], 1]
    send_command   Commands::HASH, ["footbl", @keys[6], @keys[8], 1, 1, hash_of(@rows[7..7])]

    # carrying on with the first half
    expect_command Commands::HASH, ["footbl", @keys[0], @keys[4], 2]
    send_command   Commands::HASH, ["footbl", @keys[0], @keys[4], 2, 2, hash_of(@rows[1..2])]
    expect_command Commands::HASH, ["footbl", @keys[4], @keys[6], 2]
    send_command   Commands::HASH, ["footbl", @keys[4], @keys[6], 2, 2, hash_of(@rows[5..6])]

    expect_command Commands::HASH, ["footbl", @keys[2], @keys[4], 4]
    send_command   Commands::HASH, ["footbl", @keys[2], @keys[4], 4, 2, hash_of(@rows[3..4])]

    # order from here on is just an implementation detail, but we expect to see the following commands in some order
    expect_command Commands::HASH, ["footbl", @keys[7], @keys[8], 2]
    send_command   Commands::HASH, ["footbl", @keys[7], @keys[8], 2, 1, hash_of(@rows[8..8])]
    expect_command Commands::HASH, ["footbl", @keys[2], @keys[4], 1]
    send_command   Commands::HASH, ["footbl", @keys[2], @keys[4], 1, 1, hash_of(@rows[3..3])]
    expect_command Commands::HASH, ["footbl", @keys[3], @keys[4], 1]
    send_command   Commands::HASH, ["footbl", @keys[3], @keys[4], 1, 1, hash_of(@rows[4..4])]
    expect_command Commands::ROWS,
                   ["footbl", @keys[3], @keys[4]]
    send_results   Commands::ROWS,
                   ["footbl", @keys[3], @keys[4]],
                   @rows[4]
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "handles the last row being replaced by a row with the same unique key and a later primary key" do
    clear_schema
    create_uniquetbl
    execute "INSERT INTO uniquetbl VALUES (1, 10, 'kept'), (2, 20, 'replaced')"
    @rows = [[1, 10,       "kept"],
             [3, 30, "irrelevant"],
             [4, 20,   "replacer"]]
    @rows << [@rows[-1][0] + 1, nil, "irrelevant"*100] while @rows.size < 100000 # add enough data to make the 'to' end apply the replace statement when it receives the 'replacer' row
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [uniquetbl_def]})
    expect_command Commands::RANGE, ["uniquetbl"]
    send_command   Commands::RANGE, ["uniquetbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["uniquetbl", [2], @keys[-1]]
    send_results   Commands::ROWS,
                   ["uniquetbl", [2], @keys[-1]],
                   *@rows[1..-1]
    expect_command Commands::HASH, ["uniquetbl", [], [2], 1]
    send_command   Commands::HASH, ["uniquetbl", [], [2], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["uniquetbl", [1], [2], 2]
    send_command   Commands::HASH, ["uniquetbl", [1], [2], 2, 0, hash_of([])]
    # if you receive a command here to hash 0 rows, issue 36 has regressed
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM uniquetbl ORDER BY pri")
  end

  test_each "handles data after nil elements" do
    clear_schema
    create_footbl
    expect_handshake_commands(schema: {"tables" => [footbl_def]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", [2], [3]]
    expect_command Commands::ROWS, ["footbl", [], [3]]
    send_results   Commands::ROWS,
                   ["footbl", [], [3]],
                   [2, nil, nil],
                   [3, nil,  "foo"]
    expect_quit_and_close

    assert_equal [[2, nil,   nil],
                  [3, nil, "foo"]],
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "handles hashing medium values" do
    clear_schema
    create_texttbl
    execute "INSERT INTO texttbl VALUES (0, 'test'), (1, '#{'a'*16*1024}')"

    @rows = [[0, "test"],
             [1, "a"*16*1024]]
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [texttbl_def]})
    expect_command Commands::RANGE, ["texttbl"]
    send_command   Commands::RANGE, ["texttbl", [0], [1]]
    expect_command Commands::HASH, ["texttbl", [], @keys[0], 1]
    send_command   Commands::HASH, ["texttbl", [], @keys[0], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["texttbl", [0], @keys[-1], 1]
    send_command   Commands::HASH, ["texttbl", [0], @keys[-1], 1, 1, hash_of(@rows[1..1])]
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM texttbl ORDER BY pri")
  end

  test_each "handles requesting and saving medium values" do
    clear_schema
    create_texttbl

    @rows = [[1, "a"*16*1024]]
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [texttbl_def]})
    expect_command Commands::RANGE, ["texttbl"]
    send_command   Commands::RANGE, ["texttbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["texttbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["texttbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM texttbl ORDER BY pri")
  end

  test_each "handles hashing long values" do
    clear_schema
    create_texttbl
    execute "INSERT INTO texttbl VALUES (0, 'test'), (1, '#{'a'*80*1024}')"

    @rows = [[0, "test"],
             [1, "a"*80*1024]]
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [texttbl_def]})
    expect_command Commands::RANGE, ["texttbl"]
    send_command   Commands::RANGE, ["texttbl", [0], [1]]
    expect_command Commands::HASH, ["texttbl", [], @keys[0], 1]
    send_command   Commands::HASH, ["texttbl", [], @keys[0], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["texttbl", [0], @keys[-1], 1]
    send_command   Commands::HASH, ["texttbl", [0], @keys[-1], 1, 1, hash_of(@rows[1..1])]
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM texttbl ORDER BY pri")
  end

  test_each "handles requesting and saving long values" do
    clear_schema
    create_texttbl

    @rows = [[1, "a"*80*1024]]
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [texttbl_def]})
    expect_command Commands::RANGE, ["texttbl"]
    send_command   Commands::RANGE, ["texttbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["texttbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["texttbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM texttbl ORDER BY pri")
  end

  test_each "handles requesting and saving arbitrary binary values in BLOB fields" do
    clear_schema
    create_misctbl

    bytes = (0..255).to_a.pack("C*")
    bytes = bytes.reverse + bytes
    row = [1] + [nil]*(misctbl_def["columns"].size - 1)
    row[misctbl_def["columns"].index {|c| c["name"] == "blobfield"}] = bytes
    @rows = [row]
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [misctbl_def]})
    expect_command Commands::RANGE, ["misctbl"]
    send_command   Commands::RANGE, ["misctbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["misctbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["misctbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM misctbl ORDER BY pri")
  end

  test_each "handles reusing unique values that were previously on later rows" do
    setup_with_footbl
    execute "CREATE UNIQUE INDEX unique_key ON footbl (col3)"

    @orig_rows = @rows.collect {|row| row.dup}
    @rows[0][-1] = @rows[-1][-1] # reuse this value from the last row
    @rows[-1][-1] = "new value"  # and change it there to something else

    expect_handshake_commands(schema: {"tables" => [footbl_def.merge("keys" => [{"name" => "unique_key", "unique" => true, "columns" => [2]}])]})
    expect_command Commands::RANGE, ["footbl"]
    send_command   Commands::RANGE, ["footbl", @keys[0], @keys[-1]]
    expect_command Commands::HASH, ["footbl", [], @keys[6], 1]
    send_command   Commands::HASH, ["footbl", [], @keys[6], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["footbl", @keys[6], @keys[8], 1]
    send_command   Commands::HASH, ["footbl", @keys[6], @keys[8], 1, 1, hash_of(@rows[7..7])]
    expect_command Commands::ROWS,
                   ["footbl", [], @keys[0]]
    send_results   Commands::ROWS,
                   ["footbl", [], @keys[0]],
                   @rows[0]
    expect_command Commands::HASH, ["footbl", @keys[0], @keys[4], 1]
    send_command   Commands::HASH, ["footbl", @keys[0], @keys[4], 1, 1, hash_of(@rows[1..1])]
    expect_command Commands::HASH, ["footbl", @keys[4], @keys[6], 1]
    send_command   Commands::HASH, ["footbl", @keys[4], @keys[6], 1, 1, hash_of(@rows[5..5])]
    expect_command Commands::HASH, ["footbl", @keys[1], @keys[4], 2]
    send_command   Commands::HASH, ["footbl", @keys[1], @keys[4], 2, 2, hash_of(@rows[2..3])]
    expect_command Commands::HASH, ["footbl", @keys[5], @keys[6], 2]
    send_command   Commands::HASH, ["footbl", @keys[5], @keys[6], 2, 1, hash_of(@rows[6..6])]
    expect_command Commands::HASH, ["footbl", @keys[3], @keys[4], 4]
    send_command   Commands::HASH, ["footbl", @keys[3], @keys[4], 4, 1, hash_of(@rows[4..4])]
    expect_command Commands::HASH, ["footbl", @keys[7], @keys[8], 2]
    send_command   Commands::HASH, ["footbl", @keys[7], @keys[8], 2, 1, hash_of(@rows[8..8])]
    expect_command Commands::ROWS,
                   ["footbl", @keys[7], @keys[8]]
    send_results   Commands::ROWS,
                   ["footbl", @keys[7], @keys[8]],
                   @rows[8]
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM footbl ORDER BY col1")
  end

  test_each "accepts large insert sets" do
    clear_schema
    create_texttbl

    @rows = (0..99).collect {|n| [n + 1, (97 + n % 26).chr*512*1024]}
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [texttbl_def]})
    expect_command Commands::RANGE, ["texttbl"]
    send_command   Commands::RANGE, ["texttbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["texttbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["texttbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM texttbl ORDER BY pri")
  end

  test_each "supports composite keys" do
    clear_schema
    create_secondtbl

    @rows = [[100,       100, "aa", 100], # first because aa is the first term in the key, then 100 the next
             [  9, 968116383, "aa",   9],
             [340, 363401169, "ab",  20],
             [  2,   2349174, "xy",   1]]
    @keys = @rows.collect {|row| [row[2], row[1]]}

    expect_handshake_commands(schema: {"tables" => [secondtbl_def]})
    expect_command Commands::RANGE, ["secondtbl"]
    send_command   Commands::RANGE, ["secondtbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["secondtbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["secondtbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM secondtbl ORDER BY pri2, pri1")
  end

  test_each "retrieves and reloads the whole table if there's no unique key with only non-nullable columns" do
    clear_schema
    create_noprimarytbl(create_suitable_keys: false)
    @rows = [[nil, "b968116383", 'aa', 9],
             [2,     "a2349174", 'xy', 1]]

    expect_handshake_commands(schema: {"tables" => [noprimarytbl_def(create_suitable_keys: false)]})
    # note there's no RANGE step here, since with no PK there's nothing specific to find the range of
    expect_command Commands::ROWS, ["noprimarytbl", [], []]
    send_command   Commands::ROWS,
                   ["noprimarytbl", [], []],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM noprimarytbl ORDER BY name")
  end

  test_each "retains the given values identity/serial/auto_increment primary key columns even if the database supports (and the table uses) GENERATED ALWAYS" do
    clear_schema
    table_def = autotbl_def
    table_def["columns"][0]["identity_generated_always"] = true # has no effect on mysql, but it may be sent this by postgresql anyway

    @rows = (0..99).collect {|n| [n*2 + 5, n]}
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [table_def]})
    expect_command Commands::RANGE, ["autotbl"]
    send_command   Commands::RANGE, ["autotbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["autotbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["autotbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @rows,
                 query("SELECT * FROM autotbl ORDER by inc")
  end

  test_each "skips auto-generated columns" do
    omit "Database doesn't support auto-generated columns" unless connection.supports_generated_columns?
    clear_schema
    create_generatedtbl
    execute "INSERT INTO generatedtbl (pri, fore, back) VALUES (1, 10, 100)" # insert the first row but not the second

    @rows = [[1, 10, 100],
             [2, 20, 200]]
    @keys = @rows.collect {|row| [row[0]]}

    expect_handshake_commands(schema: {"tables" => [generatedtbl_def]})
    expect_command Commands::RANGE, ["generatedtbl"]
    send_command   Commands::RANGE, ["generatedtbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["generatedtbl", @keys[0], @keys[-1]]
    send_results   Commands::ROWS,
                   ["generatedtbl", @keys[0], @keys[-1]],
                   @rows[1]
    expect_command Commands::HASH, ["generatedtbl",       [], @keys[0], 1]
    send_command   Commands::HASH, ["generatedtbl",       [], @keys[0], 1, 1, hash_of(@rows[0..0])]
    expect_quit_and_close

    assert_equal connection.supports_virtual_generated_columns? ? [[1, 10, 22, 30, 100], [2, 20, 42, 60, 200]] : [[1, 10, 22, 100], [2, 20, 42, 200]],
      query("SELECT * FROM generatedtbl ORDER BY pri")
  end

  test_each "takes the last column as the row count and inserts duplicate rows when required if the table has no real primary key or suitable unique key but has only non-nullable columns and a useful index" do
    clear_schema
    create_noprimaryjointbl(create_keys: true)

    @rows = [[3, 9, 1], # sorted earlier than the rows with lower table1_id as the (table2_id, table1_d) index will get used
             [3, 10, 2],
             [3, 11, 1],
             [1, 100, 1],
             [1, 101, 1],
             [2, 101, 1]]
    @raw_rows = [[3, 9],
                 [3, 10],
                 [3, 10],
                 [3, 11],
                 [1, 100],
                 [1, 101],
                 [2, 101]]
    @keys = @rows.collect {|row| [row[1], row[0]]}

    expect_handshake_commands(schema: {"tables" => [noprimaryjointbl_def]})
    expect_command Commands::RANGE, ["noprimaryjointbl"]
    send_command   Commands::RANGE, ["noprimaryjointbl", @keys[0], @keys[-1]]
    expect_command Commands::ROWS, ["noprimaryjointbl", [], @keys[-1]]
    send_results   Commands::ROWS,
                   ["noprimaryjointbl", [], @keys[-1]],
                   *@rows
    expect_quit_and_close

    assert_equal @raw_rows,
                 query("SELECT * FROM noprimaryjointbl ORDER BY table2_id, table1_id")
  end

  test_each "increases the number of duplicate rows if the given row count is higher than the current row count" do
    clear_schema
    create_noprimaryjointbl(create_keys: true)
    execute "INSERT INTO noprimaryjointbl (table1_id, table2_id) VALUES (1, 100), (1, 101), (2, 101), (3, 9), (3, 10), (3, 10), (3, 11)"

    @rows = [[3, 9, 1], # sorted earlier than the rows with lower table1_id as the (table2_id, table1_d) index will get used
             [3, 10, 3], # *3 this time
             [3, 11, 1]]
    @raw_rows = [[3, 9],
                 [3, 10],
                 [3, 10],
                 [3, 10],
                 [3, 11]]
    @keys = @rows.collect {|row| [row[1], row[0]]}

    expect_handshake_commands(schema: {"tables" => [noprimaryjointbl_def]})
    expect_command Commands::RANGE, ["noprimaryjointbl"]
    send_command   Commands::RANGE, ["noprimaryjointbl", @keys[0], @keys[-1]]
    expect_command Commands::HASH, ["noprimaryjointbl", [], @keys[-1], 1]
    send_command   Commands::HASH, ["noprimaryjointbl", [], @keys[-1], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 2]
    send_command   Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 2, 2, hash_of(@rows[1..2])]
    expect_command Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 1]
    send_command   Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 1, 1, hash_of(@rows[1..1])]
    expect_command Commands::ROWS, ["noprimaryjointbl", @keys[0], @keys[1]]
    send_command   Commands::ROWS, ["noprimaryjointbl", @keys[0], @keys[1]],
                                   @rows[1]
    expect_command Commands::HASH, ["noprimaryjointbl", @keys[1], @keys[-1], 1]
    send_command   Commands::HASH, ["noprimaryjointbl", @keys[1], @keys[-1], 1, 1, hash_of(@rows[2..2])]
    expect_quit_and_close

    assert_equal @raw_rows,
                 query("SELECT * FROM noprimaryjointbl ORDER BY table2_id, table1_id")
  end

  test_each "decreases the number of duplicate rows if the given row count is higher than the current row count" do
    clear_schema
    create_noprimaryjointbl(create_keys: true)
    execute "INSERT INTO noprimaryjointbl (table1_id, table2_id) VALUES (1, 100), (1, 101), (2, 101), (3, 9), (3, 10), (3, 10), (3, 10), (3, 11)"

    @rows = [[3, 9, 1], # sorted earlier than the rows with lower table1_id as the (table2_id, table1_d) index will get used
             [3, 10, 2],
             [3, 11, 1]]
    @raw_rows = [[3, 9],
                 [3, 10],
                 [3, 10],
                 [3, 11]]
    @keys = @rows.collect {|row| [row[1], row[0]]}

    expect_handshake_commands(schema: {"tables" => [noprimaryjointbl_def]})
    expect_command Commands::RANGE, ["noprimaryjointbl"]
    send_command   Commands::RANGE, ["noprimaryjointbl", @keys[0], @keys[-1]]
    expect_command Commands::HASH, ["noprimaryjointbl", [], @keys[-1], 1]
    send_command   Commands::HASH, ["noprimaryjointbl", [], @keys[-1], 1, 1, hash_of(@rows[0..0])]
    expect_command Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 2]
    send_command   Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 2, 2, hash_of(@rows[1..2])]
    expect_command Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 1]
    send_command   Commands::HASH, ["noprimaryjointbl", @keys[0], @keys[-1], 1, 1, hash_of(@rows[1..1])]
    expect_command Commands::ROWS, ["noprimaryjointbl", @keys[0], @keys[1]]
    send_command   Commands::ROWS, ["noprimaryjointbl", @keys[0], @keys[1]],
                                   @rows[1]
    expect_command Commands::HASH, ["noprimaryjointbl", @keys[1], @keys[-1], 1]
    send_command   Commands::HASH, ["noprimaryjointbl", @keys[1], @keys[-1], 1, 1, hash_of(@rows[2..2])]
    expect_quit_and_close

    assert_equal @raw_rows,
                 query("SELECT * FROM noprimaryjointbl ORDER BY table2_id, table1_id")
  end
end
