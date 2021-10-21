%%% @doc Utilities for manipulating wallets.
-module(ar_wallet).

-export([
	new/0,
	sign/2,
	verify/3, verify_pre_fork_2_4/3,
	to_address/1,
	load_keyfile/1,
	new_keyfile/0,
	new_keyfile/1,
	wallet_filepath/1
]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(PUBLIC_EXPNT, 65537).

%% @doc Generate a new wallet public key and private key.
new() ->
	{[_, Pub], [_, Pub, Priv|_]} = {[_, Pub], [_, Pub, Priv|_]}
		= crypto:generate_key(?SIGN_ALG, {?PRIV_KEY_SZ, ?PUBLIC_EXPNT}),
	{{Priv, Pub}, Pub}.

%% @doc Generate a new wallet public and private key, with a corresponding keyfile.
new_keyfile() ->
	new_keyfile(wallet_address).

%% @doc Generate a new wallet public and private key, with a corresponding keyfile.
%% The provided key is used as part of the file name.
%% @end
new_keyfile(WalletName) ->
	{[Expnt, Pub], [Expnt, Pub, Priv, P1, P2, E1, E2, C]} =
		crypto:generate_key(rsa, {?PRIV_KEY_SZ, ?PUBLIC_EXPNT}),
	Key =
		ar_serialize:jsonify(
			{
				[
					{kty, <<"RSA">>},
					{ext, true},
					{e, ar_util:encode(Expnt)},
					{n, ar_util:encode(Pub)},
					{d, ar_util:encode(Priv)},
					{p, ar_util:encode(P1)},
					{q, ar_util:encode(P2)},
					{dp, ar_util:encode(E1)},
					{dq, ar_util:encode(E2)},
					{qi, ar_util:encode(C)}
				]
			}
		),
	Filename = wallet_filepath(WalletName, Pub),
	filelib:ensure_dir(Filename),
	ar_storage:write_file_atomic(Filename, Key),
	{{Priv, Pub}, Pub}.

wallet_filepath(WalletName, PubKey) ->
	wallet_filepath(wallet_name(WalletName, PubKey)).

wallet_filepath(Wallet) ->
	{ok, Config} = application:get_env(arweave, config),
	Filename = lists:flatten(["arweave_keyfile_", binary_to_list(Wallet), ".json"]),
	filename:join([Config#config.data_dir, ?WALLET_DIR, Filename]).

wallet_name(wallet_address, PubKey) ->
	ar_util:encode(to_address(PubKey));
wallet_name(WalletName, _) ->
	WalletName.

%% @doc Extract the public and private key from a keyfile.
load_keyfile(File) ->
	{ok, Body} = file:read_file(File),
	{Key} = ar_serialize:dejsonify(Body),
	{<<"n">>, PubEncoded} = lists:keyfind(<<"n">>, 1, Key),
	Pub = ar_util:decode(PubEncoded),
	{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
	Priv = ar_util:decode(PrivEncoded),
	{{Priv, Pub}, Pub}.

%% @doc Sign some data with a private key.
sign({Priv, Pub}, Data) ->
	rsa_pss:sign(
		Data,
		sha256,
		#'RSAPrivateKey'{
			publicExponent = ?PUBLIC_EXPNT,
			modulus = binary:decode_unsigned(Pub),
			privateExponent = binary:decode_unsigned(Priv)
		}
	).

%% @doc Verify that a signature is correct.
verify(Key, Data, Sig) ->
	rsa_pss:verify(
		Data,
		sha256,
		Sig,
		#'RSAPublicKey'{
			publicExponent = ?PUBLIC_EXPNT,
			modulus = binary:decode_unsigned(Key)
		}
	).

%% @doc Verify that a signature is correct. The function was used to verify
%% transactions until the fork 2.4. It rejects a valid transaction when the
%% key modulus bit size is less than 4096. The new method (verify/3) successfully
%% verifies all the historical transactions so this function is not used anywhere
%% after the fork 2.4.
%% @end
verify_pre_fork_2_4(Key, Data, Sig) ->
	rsa_pss:verify_legacy(
		Data,
		sha256,
		Sig,
		#'RSAPublicKey'{
			publicExponent = ?PUBLIC_EXPNT,
			modulus = binary:decode_unsigned(Key)
		}
	).

%% @doc Generate an address from a public key.
to_address(Addr) when ?IS_ADDR(Addr) -> Addr;
to_address({{_, Pub}, Pub}) -> to_address(Pub);
to_address({_, Pub}) -> to_address(Pub);
to_address(PubKey) ->
	crypto:hash(?HASH_ALG, PubKey).

%%%===================================================================
%%% Tests.
%%%===================================================================

wallet_sign_verify_test() ->
	TestData = <<"TEST DATA">>,
	{Priv, Pub} = new(),
	Signature = sign(Priv, TestData),
	true = verify(Pub, TestData, Signature).

invalid_signature_test() ->
	TestData = <<"TEST DATA">>,
	{Priv, Pub} = new(),
	<< _:32, Signature/binary >> = sign(Priv, TestData),
	false = verify(Pub, TestData, << 0:32, Signature/binary >>).

%% @doc Ensure that to_address'ing twice does not result in double hashing.
address_double_encode_test() ->
	{_, Pub} = new(),
	Addr = to_address(Pub),
	Addr = to_address(Addr).

%% @doc Check generated keyfiles can be retrieved.
generate_keyfile_test() ->
	{Priv, Pub} = new_keyfile(),
	FileName = wallet_filepath(ar_util:encode(to_address(Pub))),
	{Priv, Pub} = load_keyfile(FileName).
