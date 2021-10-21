-module(ar_data_sync_tests).

-include_lib("eunit/include/eunit.hrl").

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_data_sync.hrl").

-import(ar_test_node, [
	start/1,
	slave_start/1,
	connect_to_slave/0,
	sign_tx/2,
	sign_v1_tx/2,
	wait_until_height/1,
	slave_wait_until_height/1,
	post_and_mine/2,
	get_tx_anchor/1,
	disconnect_from_slave/0,
	join_on_master/0,
	assert_post_tx_to_slave/1,
	assert_post_tx_to_master/1,
	wait_until_receives_txs/1,
	slave_mine/0,
	read_block_when_stored/1,
	get_chunk/1, get_chunk/2, post_chunk/1, post_chunk/2
]).

rejects_invalid_chunks_test_() ->
	{timeout, 20, fun test_rejects_invalid_chunks/0}.

test_rejects_invalid_chunks() ->
	{_Master, _, _Wallet} = setup_nodes(),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"chunk_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			chunk => ar_util:encode(crypto:strong_rand_bytes(?DATA_CHUNK_SIZE + 1)),
			data_path => <<>>,
			offset => <<"0">>,
			data_size => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"data_path_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			data_path => ar_util:encode(crypto:strong_rand_bytes(?MAX_PATH_SIZE + 1)),
			chunk => <<>>,
			offset => <<"0">>,
			data_size => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"offset_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			offset => integer_to_binary(trunc(math:pow(2, 256))),
			data_path => <<>>,
			chunk => <<>>,
			data_size => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"data_size_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			data_size => integer_to_binary(trunc(math:pow(2, 256))),
			data_path => <<>>,
			chunk => <<>>,
			offset => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"chunk_proof_ratio_not_attractive\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			chunk => ar_util:encode(<<"a">>),
			data_path => ar_util:encode(<<"bb">>),
			offset => <<"0">>,
			data_size => <<"0">>
		}))
	),
	setup_nodes(),
	Chunk = crypto:strong_rand_bytes(500),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
		ar_tx:chunks_to_size_tagged_chunks([Chunk])
	),
	{DataRoot, DataTree} = ar_merkle:generate_tree(SizedChunkIDs),
	DataPath = ar_merkle:generate_path(DataRoot, 0, DataTree),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"data_root_not_found\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			data_root => ar_util:encode(DataRoot),
			chunk => ar_util:encode(Chunk),
			data_path => ar_util:encode(DataPath),
			offset => <<"0">>,
			data_size => <<"500">>
		}))
	),
	?assertMatch(
		{ok, {{<<"413">>, _}, _, <<"Payload too large">>, _, _}},
		post_chunk(<< <<0>> || _ <- lists:seq(1, ?MAX_SERIALIZED_CHUNK_PROOF_SIZE + 1) >>)
	).

accepts_chunk_with_out_of_outer_bounds_offset_test_() ->
	{timeout, 60, fun test_accepts_chunk_with_out_of_outer_bounds_offset/0}.

test_accepts_chunk_with_out_of_outer_bounds_offset() ->
	{Master, _, Wallet} = setup_nodes(),
	DataSize = 10000,
	OutOfBoundsOffsetChunk = crypto:strong_rand_bytes(DataSize),
	ChunkID = ar_tx:generate_chunk_id(OutOfBoundsOffsetChunk),
	{DataRoot, DataTree} = ar_merkle:generate_tree([{ChunkID, DataSize + 1}]),
	TX = sign_tx(
		Wallet,
		#{ last_tx => get_tx_anchor(master), data_size => DataSize, data_root => DataRoot }
	),
	post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [TX]),
	DataPath = ar_merkle:generate_path(DataRoot, 0, DataTree),
	Proof = #{
		data_root => ar_util:encode(DataRoot),
		data_path => ar_util:encode(DataPath),
		chunk => ar_util:encode(OutOfBoundsOffsetChunk),
		offset => <<"0">>,
		data_size => integer_to_binary(DataSize)
	},
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(Proof))
	),
	wait_until_syncs_chunk(DataSize),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(DataSize + 1)
	),
	BigOutOfBoundsOffsetChunk = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	BigChunkID = ar_tx:generate_chunk_id(BigOutOfBoundsOffsetChunk),
	{BigDataRoot, BigDataTree} = ar_merkle:generate_tree([{BigChunkID, ?DATA_CHUNK_SIZE + 1}]),
	BigTX = sign_tx(
		Wallet,
		#{
			last_tx => get_tx_anchor(master),
			data_size => ?DATA_CHUNK_SIZE,
			data_root => BigDataRoot
		}
	),
	post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [BigTX]),
	BigDataPath = ar_merkle:generate_path(BigDataRoot, 0, BigDataTree),
	BigProof = #{
		data_root => ar_util:encode(BigDataRoot),
		data_path => ar_util:encode(BigDataPath),
		chunk => ar_util:encode(BigOutOfBoundsOffsetChunk),
		offset => <<"0">>,
		data_size => integer_to_binary(?DATA_CHUNK_SIZE)
	},
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"invalid_proof\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(BigProof))
	).

accepts_chunk_with_out_of_inner_bounds_offset_test_() ->
	{timeout, 60, fun test_accepts_chunk_with_out_of_inner_bounds_offset/0}.

test_accepts_chunk_with_out_of_inner_bounds_offset() ->
	{Master, _, Wallet} = setup_nodes(),
	ChunkSize = 1000,
	Chunk = crypto:strong_rand_bytes(ChunkSize),
	FirstChunkID = ar_tx:generate_chunk_id(Chunk),
	FirstHash = hash([hash(FirstChunkID), hash(<< (ChunkSize + 500):256 >>)]),
	SecondHash = crypto:strong_rand_bytes(32),
	InvalidDataPath = iolist_to_binary([
		<< FirstHash/binary, SecondHash/binary, ChunkSize:256>> |
		<< FirstChunkID/binary, (ChunkSize + 500):256 >>
	]),
	DataRoot = hash([hash(FirstHash), hash(SecondHash), hash(<< ChunkSize:256 >>)]),
	TX = sign_tx(
		Wallet,
		#{
			last_tx => get_tx_anchor(master),
			data_root => DataRoot,
			data_size => 2 * ChunkSize
		}
	),
	B1 = post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [TX]),
	InvalidProof = #{
		data_root => ar_util:encode(DataRoot),
		data_path => ar_util:encode(InvalidDataPath),
		chunk => ar_util:encode(Chunk),
		offset => <<"0">>,
		data_size => integer_to_binary(2 * ChunkSize)
	},
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(InvalidProof))
	),
	wait_until_syncs_chunk(ChunkSize),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(ChunkSize + 1)
	),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(ChunkSize + 400)
	),
	Chunk2 = crypto:strong_rand_bytes(2 * ChunkSize),
	FirstChunkID2 = ar_tx:generate_chunk_id(Chunk2),
	FirstHash2 = hash([hash(FirstChunkID2), hash(<< (2 * ChunkSize):256 >>)]),
	InvalidDataPath2 = iolist_to_binary([
		<< FirstHash2/binary, SecondHash/binary, (2 * ChunkSize + 500):256>> |
		<< FirstChunkID2/binary, (2 * ChunkSize):256 >>
	]),
	DataRoot2 = hash([hash(FirstHash2), hash(SecondHash), hash(<< (2 * ChunkSize + 500):256 >>)]),
	TX2 = sign_tx(
		Wallet,
		#{
			last_tx => get_tx_anchor(master),
			data_root => DataRoot2,
			data_size => 2 * ChunkSize
		}
	),
	post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [TX2]),
	InvalidProof2 = #{
		data_root => ar_util:encode(DataRoot2),
		data_path => ar_util:encode(InvalidDataPath2),
		chunk => ar_util:encode(Chunk2),
		offset => <<"0">>,
		data_size => integer_to_binary(2 * ChunkSize)
	},
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(InvalidProof2))
	),
	wait_until_syncs_chunk(B1#block.weave_size + 2 * ChunkSize),
	wait_until_syncs_chunk(B1#block.weave_size + 1),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(B1#block.weave_size + 2 * ChunkSize + 1)
	),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(B1#block.weave_size + 2 * ChunkSize + 400)
	),
	BigChunk = crypto:strong_rand_bytes(ChunkSize),
	BigChunkID = ar_tx:generate_chunk_id(BigChunk),
	BigFirstHash = hash([hash(BigChunkID), hash(<< (ChunkSize + ?DATA_CHUNK_SIZE):256 >>)]),
	BigSecondHash = crypto:strong_rand_bytes(32),
	BigInvalidDataPath = iolist_to_binary([
		<< BigFirstHash/binary, BigSecondHash/binary, ChunkSize:256>> |
		<< BigChunkID/binary, (ChunkSize + ?DATA_CHUNK_SIZE):256 >>
	]),
	BigDataRoot = hash([hash(BigFirstHash), hash(BigSecondHash), hash(<< ChunkSize:256 >>)]),
	BigTX = sign_tx(
		Wallet,
		#{
			last_tx => get_tx_anchor(master),
			data_root => BigDataRoot,
			data_size => 2 * ?DATA_CHUNK_SIZE
		}
	),
	post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [BigTX]),
	BigInvalidProof = #{
		data_root => ar_util:encode(BigDataRoot),
		data_path => ar_util:encode(BigInvalidDataPath),
		chunk => ar_util:encode(BigChunk),
		offset => <<"0">>,
		data_size => integer_to_binary(2 * ?DATA_CHUNK_SIZE)
	},
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"invalid_proof\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(BigInvalidProof))
	).

rejects_chunks_exceeding_disk_pool_limit_test_() ->
	{timeout, 60, fun test_rejects_chunks_exceeding_disk_pool_limit/0}.

test_rejects_chunks_exceeding_disk_pool_limit() ->
	{_Master, _Slave, Wallet} = setup_nodes(),
	Data1 = crypto:strong_rand_bytes(
		(?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB * 1024 * 1024) + 1
	),
	Chunks1 = split(?DATA_CHUNK_SIZE, Data1),
	{DataRoot1, _} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks1)
		)
	),
	{TX1, Chunks1} = tx(Wallet, {fixed_data, Data1, DataRoot1, Chunks1}),
	assert_post_tx_to_master(TX1),
	[{_, FirstProof1} | Proofs1] = build_proofs(TX1, Chunks1, [TX1], 0),
	lists:foreach(
		fun({_, Proof}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		Proofs1
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"exceeds_disk_pool_size_limit\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(FirstProof1))
	),
	Data2 = crypto:strong_rand_bytes(
		min(
			?DEFAULT_MAX_DISK_POOL_BUFFER_MB - ?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB,
			?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB - 1
		) * 1024 * 1024
	),
	Chunks2 = split(Data2),
	{DataRoot2, _} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks2)
		)
	),
	{TX2, Chunks2} = tx(Wallet, {fixed_data, Data2, DataRoot2, Chunks2}),
	assert_post_tx_to_master(TX2),
	Proofs2 = build_proofs(TX2, Chunks2, [TX2], 0),
	lists:foreach(
		fun({_, Proof}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		Proofs2
	),
	Left =
		?DEFAULT_MAX_DISK_POOL_BUFFER_MB * 1024 * 1024 -
		lists:sum([byte_size(Chunk) || Chunk <- tl(Chunks1)]) -
		byte_size(Data2),
	?assert(Left < ?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB * 1024 * 1024),
	Data3 = crypto:strong_rand_bytes(Left + 1),
	Chunks3 = split(Data3),
	{DataRoot3, _} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks3)
		)
	),
	{TX3, Chunks3} = tx(Wallet, {fixed_data, Data3, DataRoot3, Chunks3}),
	assert_post_tx_to_master(TX3),
	[{_, FirstProof3} | Proofs3] = build_proofs(TX3, Chunks3, [TX3], 0),
	lists:foreach(
		fun({_, Proof}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		Proofs3
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"exceeds_disk_pool_size_limit\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(FirstProof3))
	),
	slave_mine(),
	true = ar_util:do_until(
		fun() ->
			lists:all(
				fun(Proof) ->
					case post_chunk(ar_serialize:jsonify(Proof)) of
						{ok, {{<<"200">>, _}, _, _, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				[FirstProof1, FirstProof3]
			)
		end,
		500,
		10 * 1000
	).

accepts_chunks_test_() ->
	{timeout, 60, fun test_accepts_chunks/0}.

test_accepts_chunks() ->
	{_Master, _Slave, Wallet} = setup_nodes(),
	{TX, Chunks} = tx(Wallet, {custom_split, 3}),
	assert_post_tx_to_slave(TX),
	wait_until_receives_txs([TX]),
	[{EndOffset, FirstProof}, {_, SecondProof}, {_, ThirdProof}] =
		build_proofs(TX, Chunks, [TX], 0),
	%% Post the third proof to the disk pool.
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(ThirdProof))
	),
	slave_mine(),
	[{BH, _, _} | _] = wait_until_height(1),
	B = read_block_when_stored(BH),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(EndOffset)
	),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(FirstProof))
	),
	%% Expect the chunk to be retrieved by any offset within
	%% (EndOffset - ChunkSize, EndOffset], but not outside of it.
	FirstChunk = ar_util:decode(maps:get(chunk, FirstProof)),
	FirstChunkSize = byte_size(FirstChunk),
	ExpectedProof = #{
		data_path => maps:get(data_path, FirstProof),
		tx_path => maps:get(tx_path, FirstProof),
		chunk => ar_util:encode(FirstChunk)
	},
	wait_until_syncs_chunk(EndOffset, ExpectedProof),
	wait_until_syncs_chunk(EndOffset - rand:uniform(FirstChunkSize - 2), ExpectedProof),
	wait_until_syncs_chunk(EndOffset - FirstChunkSize + 1, ExpectedProof),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(EndOffset - FirstChunkSize)
	),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(EndOffset + 1)
	),
	TXSize = byte_size(binary:list_to_bin(Chunks)),
	ExpectedOffsetInfo = ar_serialize:jsonify(#{
		offset => integer_to_binary(TXSize),
		size => integer_to_binary(TXSize)
	}),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, ExpectedOffsetInfo, _, _}},
		get_tx_offset(TX#tx.id)
	),
	%% Expect no transaction data because the second chunk is not synced yet.
	?assertMatch(
		{ok, {{<<"200">>, _}, _, <<>>, _, _}},
		get_tx_data(TX#tx.id)
	),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(SecondProof))
	),
	ExpectedSecondProof = #{
		data_path => maps:get(data_path, SecondProof),
		tx_path => maps:get(tx_path, SecondProof),
		chunk => maps:get(chunk, SecondProof)
	},
	SecondChunk = ar_util:decode(maps:get(chunk, SecondProof)),
	SecondChunkOffset = FirstChunkSize + byte_size(SecondChunk),
	wait_until_syncs_chunk(SecondChunkOffset, ExpectedSecondProof),
	true = ar_util:do_until(
		fun() ->
			{ok, {{<<"200">>, _}, _, Data, _, _}} = get_tx_data(TX#tx.id),
			ar_util:encode(binary:list_to_bin(Chunks)) == Data
		end,
		500,
		10 * 1000
	),
	ExpectedThirdProof = #{
		data_path => maps:get(data_path, ThirdProof),
		tx_path => maps:get(tx_path, ThirdProof),
		chunk => maps:get(chunk, ThirdProof)
	},
	wait_until_syncs_chunk(B#block.weave_size, ExpectedThirdProof),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(B#block.weave_size + 1)
	).

syncs_data_test_() ->
	{timeout, 180, fun test_syncs_data/0}.

test_syncs_data() ->
	{_Master, _Slave, Wallet} = setup_nodes(),
	Records = post_random_blocks(Wallet),
	RecordsWithProofs = lists:flatmap(
		fun({B, TX, Chunks}) ->
			[{B, TX, Chunks, Proof} || Proof <- build_proofs(B, TX, Chunks)]
		end,
		Records
	),
	lists:foreach(
		fun({_, _, _, {_, Proof}}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			),
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		RecordsWithProofs
	),
	slave_wait_until_syncs_chunks([Proof || {_, _, _, Proof} <- RecordsWithProofs]),
	lists:foreach(
		fun({B, #tx{ id = TXID }, Chunks, {_, Proof}}) ->
			TXSize = byte_size(binary:list_to_bin(Chunks)),
			TXOffset = ar_merkle:extract_note(ar_util:decode(maps:get(tx_path, Proof))),
			AbsoluteTXOffset = B#block.weave_size - B#block.block_size + TXOffset,
			ExpectedOffsetInfo = ar_serialize:jsonify(#{
				offset => integer_to_binary(AbsoluteTXOffset),
				size => integer_to_binary(TXSize)
			}),
			true = ar_util:do_until(
				fun() ->
					case get_tx_offset_from_slave(TXID) of
						{ok, {{<<"200">>, _}, _, ExpectedOffsetInfo, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				100,
				60 * 1000
			)
		end,
		RecordsWithProofs
	),
	lists:foreach(
		fun({_, #tx{ id = TXID }, Chunks, _}) ->
			ExpectedData = ar_util:encode(binary:list_to_bin(Chunks)),
			true = ar_util:do_until(
				fun() ->
					case get_tx_data_from_slave(TXID) of
						{ok, {{<<"200">>, _}, _, ExpectedData, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				100,
				60 * 1000
			)
		end,
		RecordsWithProofs
	).

fork_recovery_test_() ->
	{timeout, 180, fun test_fork_recovery/0}.

test_fork_recovery() ->
	{Master, Slave, Wallet} = setup_nodes(),
	{TX1, Chunks1} = tx(Wallet, {custom_split, 3}),
	B1 = post_and_mine(#{ miner => {master, Master}, await_on => {slave, Slave} }, [TX1]),
	Proofs1 = post_proofs_to_master(B1, TX1, Chunks1),
	slave_wait_until_syncs_chunks(Proofs1),
	disconnect_from_slave(),
	{SlaveTX2, SlaveChunks2} = tx(Wallet, {custom_split, 5}),
	{SlaveTX3, SlaveChunks3} = tx(Wallet, {custom_split, 3}),
	SlaveB2 = post_and_mine(
		#{ miner => {slave, Slave}, await_on => {slave, Slave} },
		[SlaveTX2, SlaveTX3]
	),
	connect_to_slave(),
	{MasterTX2, MasterChunks2} = tx(Wallet, {custom_split, 4}),
	MasterB2 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[MasterTX2]
	),
	disconnect_from_slave(),
	_SlaveProofs2 = post_proofs_to_slave(SlaveB2, SlaveTX2, SlaveChunks2),
	_SlaveProofs3 = post_proofs_to_slave(SlaveB2, SlaveTX3, SlaveChunks3),
	{SlaveTX4, SlaveChunks4} = tx(Wallet, {custom_split, 2}),
	SlaveB3 = post_and_mine(
		#{ miner => {slave, Slave}, await_on => {slave, Slave} },
		[SlaveTX4]
	),
	connect_to_slave(),
	post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[]
	),
	MasterProofs2 = post_proofs_to_master(MasterB2, MasterTX2, MasterChunks2),
	{MasterTX3, MasterChunks3} = tx(Wallet, {custom_split, 6}),
	MasterB3 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[MasterTX3]
	),
	MasterProofs3 = post_proofs_to_master(MasterB3, MasterTX3, MasterChunks3),
	slave_wait_until_syncs_chunks(MasterProofs2),
	slave_wait_until_syncs_chunks(MasterProofs3),
	slave_wait_until_syncs_chunks(Proofs1),
	MasterB4 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[SlaveTX2, SlaveTX4]
	),
	Proofs4 = build_proofs(MasterB4, SlaveTX2, SlaveChunks2),
	%% We did not submit proofs for SlaveTX2 - they are supposed to be still stored
	%% in the disk pool.
	slave_wait_until_syncs_chunks(Proofs4),
	wait_until_syncs_chunks(Proofs4),
	post_proofs_to_slave(SlaveB3, SlaveTX4, SlaveChunks4).

syncs_after_joining_test_() ->
	{timeout, 180, fun test_syncs_after_joining/0}.

test_syncs_after_joining() ->
	{Master, Slave, Wallet} = setup_nodes(),
	{TX1, Chunks1} = tx(Wallet, {custom_split, 1}),
	B1 = post_and_mine(#{ miner => {master, Master}, await_on => {slave, Slave} }, [TX1]),
	Proofs1 = post_proofs_to_master(B1, TX1, Chunks1),
	slave_wait_until_syncs_chunks(Proofs1),
	disconnect_from_slave(),
	{MasterTX2, MasterChunks2} = tx(Wallet, {custom_split, 3}),
	MasterB2 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[MasterTX2]
	),
	MasterProofs2 = post_proofs_to_master(MasterB2, MasterTX2, MasterChunks2),
	{MasterTX3, MasterChunks3} = tx(Wallet, {custom_split, 2}),
	MasterB3 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[MasterTX3]
	),
	MasterProofs3 = post_proofs_to_master(MasterB3, MasterTX3, MasterChunks3),
	{SlaveTX2, SlaveChunks2} = tx(Wallet, {custom_split, 20}),
	SlaveB2 = post_and_mine(
		#{ miner => {slave, Slave}, await_on => {slave, Slave} },
		[SlaveTX2]
	),
	SlaveProofs2 = post_proofs_to_slave(SlaveB2, SlaveTX2, SlaveChunks2),
	slave_wait_until_syncs_chunks(SlaveProofs2),
	_Slave2 = join_on_master(),
	slave_wait_until_height(3),
	connect_to_slave(),
	slave_wait_until_syncs_chunks(MasterProofs2),
	slave_wait_until_syncs_chunks(MasterProofs3),
	slave_wait_until_syncs_chunks(Proofs1).

setup_nodes() ->
	Wallet = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(200), <<>>}]),
	{Master, _} = start(B0),
	{Slave, _} = slave_start(B0),
	connect_to_slave(),
	{Master, Slave, Wallet}.

tx(Wallet, SplitType) ->
	tx(Wallet, SplitType, v2).

v1_tx(Wallet) ->
	tx(Wallet, original_split, v1).

tx(Wallet, SplitType, Format) ->
	case {SplitType, Format} of
		{{fixed_data, Data, DataRoot, Chunks}, _} ->
			{sign_tx(Wallet, #{
				data_size => byte_size(Data),
				data_root => DataRoot,
				last_tx => get_tx_anchor(master)
			}), Chunks};
		{original_split, v1} ->
			%% Make sure v1 data does not end with a digit, otherwise it's malleable.
			Data = << (crypto:strong_rand_bytes(1024 * 1024 - 1))/binary, <<"a">>/binary >>,
			{_, Chunks} = original_split(Data),
			{sign_v1_tx(Wallet, #{ data => Data, last_tx => get_tx_anchor(master) }), Chunks};
		{{custom_split, ChunkNumber}, v2} ->
			Chunks = lists:foldl(
				fun(_, Chunks) ->
					OneThird = ?DATA_CHUNK_SIZE div 3,
					RandomSize = OneThird + rand:uniform(?DATA_CHUNK_SIZE - OneThird) - 1,
					Chunk = crypto:strong_rand_bytes(RandomSize),
					[Chunk | Chunks]
				end,
				[],
				lists:seq(
					1,
					case ChunkNumber of random -> rand:uniform(5); _ -> ChunkNumber end
				)
			),
			SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
				ar_tx:chunks_to_size_tagged_chunks(Chunks)
			),
			{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
			TX = sign_tx(Wallet, #{
				data_size => byte_size(binary:list_to_bin(Chunks)),
				last_tx => get_tx_anchor(master),
				data_root => DataRoot
			}),
			{TX, Chunks};
		{original_split, v2} ->
			Data = crypto:strong_rand_bytes(11 * 1024),
			{DataRoot, Chunks} = original_split(Data),
			TX = sign_tx(Wallet, #{
				data_size => byte_size(Data),
				last_tx => get_tx_anchor(master),
				data_root => DataRoot
			}),
			{TX, Chunks}
	end.

original_split(Data) ->
	Chunks = ar_tx:chunk_binary(?DATA_CHUNK_SIZE, Data),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
		ar_tx:chunks_to_size_tagged_chunks(Chunks)
	),
	{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
	{DataRoot, Chunks}.

split(Data) ->
	split(?DATA_CHUNK_SIZE, Data).

split(_ChunkSize, Bin) when byte_size(Bin) == 0 ->
	[];
split(ChunkSize, Bin) when byte_size(Bin) < ChunkSize ->
	[Bin];
split(ChunkSize, Bin) ->
	<<ChunkBin:ChunkSize/binary, Rest/binary>> = Bin,
	HalfSize = ChunkSize div 2,
	case byte_size(Rest) < HalfSize of
		true ->
			HalfSize = ChunkSize div 2,
			<<ChunkBin2:HalfSize/binary, Rest2/binary>> = Bin,
			[ChunkBin2, Rest2];
		false ->
			[ChunkBin | split(ChunkSize, Rest)]
	end.

build_proofs(B, TX, Chunks) ->
	build_proofs(TX, Chunks, B#block.txs, B#block.weave_size - B#block.block_size).

build_proofs(TX, Chunks, TXs, BlockStartOffset) ->
	SizeTaggedTXs = ar_block:generate_size_tagged_list_from_txs(TXs),
	SizeTaggedDataRoots = [{Root, Offset} || {{_, Root}, Offset} <- SizeTaggedTXs],
	{value, {_, TXOffset}} =
		lists:search(fun({{TXID, _}, _}) -> TXID == TX#tx.id end, SizeTaggedTXs),
	{TXRoot, TXTree} = ar_merkle:generate_tree(SizeTaggedDataRoots),
	TXPath = ar_merkle:generate_path(TXRoot, TXOffset - 1, TXTree),
	SizeTaggedChunks = ar_tx:chunks_to_size_tagged_chunks(Chunks),
	{DataRoot, DataTree} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(SizeTaggedChunks)
	),
	DataSize = byte_size(binary:list_to_bin(Chunks)),
	lists:foldl(
		fun
			({<<>>, _}, Proofs) ->
				Proofs;
			({Chunk, ChunkOffset}, Proofs) ->
				TXStartOffset = TXOffset - DataSize,
				AbsoluteChunkEndOffset = BlockStartOffset + TXStartOffset + ChunkOffset,
				Proof = #{
					tx_path => ar_util:encode(TXPath),
					data_root => ar_util:encode(DataRoot),
					data_path =>
						ar_util:encode(
							ar_merkle:generate_path(DataRoot, ChunkOffset - 1, DataTree)
						),
					chunk => ar_util:encode(Chunk),
					offset => integer_to_binary(ChunkOffset - 1),
					data_size => integer_to_binary(DataSize)
				},
				Proofs ++ [{AbsoluteChunkEndOffset, Proof}]
		end,
		[],
		SizeTaggedChunks
	).

get_tx_offset(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1984},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/offset"
	}).

get_tx_data(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1984},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/data"
	}).

get_tx_offset_from_slave(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1983},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/offset"
	}).

get_tx_data_from_slave(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1983},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/data"
	}).

post_random_blocks(Wallet) ->
	post_blocks(Wallet,
		[
			[v1],
			empty,
			[v2, v1, fixed_data, v2_no_data],
			[v2, v2_original_split, v1, v2],
			empty,
			[v1, v2, v2, empty_tx, v2_original_split],
			[v2, v2_no_data, v2_no_data, v1, v2_no_data],
			[empty_tx],
			empty,
			[v2_original_split, v2_no_data, v2, v1, v2],
			empty,
			[fixed_data, fixed_data],
			empty,
			[fixed_data, fixed_data] % same tx_root as in the block before the previous one
		]
	).

post_blocks(Wallet, BlockMap) ->
	FixedChunks = [crypto:strong_rand_bytes(200 * 1024) || _ <- lists:seq(1, 4)],
	Data = iolist_to_binary(lists:foldl(fun(Chunk, Acc) -> [Acc | Chunk] end, [], FixedChunks)),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
		ar_tx:chunks_to_size_tagged_chunks(FixedChunks)
	),
	{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
	lists:foldl(
		fun
			({empty, Height}, Acc) ->
				ar_node:mine(),
				slave_wait_until_height(Height),
				Acc;
			({TXMap, _Height}, Acc) ->
				TXsWithChunks = lists:map(
					fun
						(v1) ->
							{v1_tx(Wallet), v1};
						(v2) ->
							{tx(Wallet, {custom_split, random}), v2};
						(v2_no_data) -> % same as v2 but its data won't be submitted
							{tx(Wallet, {custom_split, random}), v2_no_data};
						(v2_original_split) ->
							{tx(Wallet, original_split), v2_original_split};
						(empty_tx) ->
							{tx(Wallet, {custom_split, 0}), empty_tx};
						(fixed_data) ->
							{tx(Wallet, {fixed_data, Data, DataRoot, FixedChunks}), fixed_data}
					end,
					TXMap
				),
				B = post_and_mine(
					#{ miner => {master, "master"}, await_on => {master, "master"} },
					[TX || {{TX, _}, _} <- TXsWithChunks]
				),
				Acc ++ [{B, TX, C} || {{TX, C}, Type} <- lists:sort(TXsWithChunks),
						Type /= v2_no_data, Type /= empty_tx]
		end,
		[],
		lists:zip(BlockMap, lists:seq(1, length(BlockMap)))
	).

post_proofs_to_master(B, TX, Chunks) ->
	post_proofs(master, B, TX, Chunks).

post_proofs_to_slave(B, TX, Chunks) ->
	post_proofs(slave, B, TX, Chunks).

post_proofs(Peer, B, TX, Chunks) ->
	Proofs = build_proofs(B, TX, Chunks),
	lists:foreach(
		fun({_, Proof}) ->
			{ok, {{<<"200">>, _}, _, _, _, _}} =
				post_chunk(Peer, ar_serialize:jsonify(Proof))
		end,
		Proofs
	),
	Proofs.

wait_until_syncs_chunk(Offset) ->
	true = ar_util:do_until(
		fun() ->
			case get_chunk(Offset) of
				{ok, {{<<"200">>, _}, _, _, _, _}} ->
					true;
				_ ->
					false
			end
		end,
		100,
		5000
	).

wait_until_syncs_chunk(Offset, ExpectedProof) ->
	true = ar_util:do_until(
		fun() ->
			case get_chunk(Offset) of
				{ok, {{<<"200">>, _}, _, ProofJSON, _, _}} ->
					Proof = jiffy:decode(ProofJSON, [return_maps]),
					maps:fold(
						fun	(_Key, _Value, false) ->
								false;
							(Key, Value, true) ->
								maps:get(atom_to_binary(Key), Proof, not_set) == Value
						end,
						true,
						ExpectedProof
					);
				_ ->
					false
			end
		end,
		100,
		5000
	).

wait_until_syncs_chunks(Proofs) ->
	wait_until_syncs_chunks(master, Proofs).

slave_wait_until_syncs_chunks(Proofs) ->
	wait_until_syncs_chunks(slave, Proofs).

wait_until_syncs_chunks(Peer, Proofs) ->
	lists:foreach(
		fun({EndOffset, Proof}) ->
			true = ar_util:do_until(
				fun() ->
					case get_chunk(Peer, EndOffset) of
						{ok, {{<<"200">>, _}, _, EncodedProof, _, _}} ->
							FetchedProof = ar_serialize:json_map_to_chunk_proof(
								jiffy:decode(EncodedProof, [return_maps])
							),
							ExpectedProof = #{
								chunk => ar_util:decode(maps:get(chunk, Proof)),
								tx_path => ar_util:decode(maps:get(tx_path, Proof)),
								data_path => ar_util:decode(maps:get(data_path, Proof))
							},
							compare_proofs(FetchedProof, ExpectedProof);
						_ ->
							false
					end
				end,
				5 * 1000,
				120 * 1000
			)
		end,
		Proofs
	).

compare_proofs(
	#{ chunk := C, data_path := D, tx_path := T },
	#{ chunk := C, data_path := D, tx_path := T }
) ->
	true;
compare_proofs(_, _) ->
	false.

hash(Parts) when is_list(Parts) ->
	crypto:hash(sha256, binary:list_to_bin(Parts));
hash(Binary) ->
	crypto:hash(sha256, Binary).
