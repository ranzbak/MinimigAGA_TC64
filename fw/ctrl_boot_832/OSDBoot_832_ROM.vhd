library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity OSDBoot_832_ROM is
generic
	(
		ADDR_WIDTH : integer := 15; -- Specify your actual ROM size to save LEs and unnecessary block RAM usage.
        COL_WIDTH  : integer := 8;  -- Column width (8bit -> byte)
        NB_COL     : integer := 4  -- Number of columns in memory
	);
port (
	clk : in std_logic;
	reset_n : in std_logic := '1';
	addr : in std_logic_vector(ADDR_WIDTH-2 downto 0);
	q : out std_logic_vector(31 downto 0);
	-- Allow writes - defaults supplied to simplify projects that don't need to write.
	d : in std_logic_vector(31 downto 0) := X"00000000";
	we : in std_logic := '0';
	bytesel : in std_logic_vector(3 downto 0) := "1111";
	-- Second port
	addr2 : in std_logic_vector(ADDR_WIDTH-2 downto 0) := (others=>'0');
	q2 : out std_logic_vector(31 downto 0);
	d2 : in std_logic_vector(31 downto 0) := X"00000000";
	we2 : in std_logic := '0';
	bytesel2 : in std_logic_vector(3 downto 0) := "1111"	
);
end OSDBoot_832_ROM;

architecture arch of OSDBoot_832_ROM is

-- type word_t is std_logic_vector(31 downto 0);
type ram_type is array (0 to 2 ** (ADDR_WIDTH-1) - 1) of std_logic_vector(NB_COL * COL_WIDTH - 1 downto 0);

   -- type rom_type is array (0 to 2**ADDR_WIDTH-1)
   --     of std_logic_vector(DATA_WIDTH-1 downto 0);

signal ram : ram_type :=
(
     0 => x"01da8704",
     1 => x"dd870e58",
     2 => x"5e595a0e",
     3 => x"27000000",
     4 => x"2c0f264a",
     5 => x"26492648",
     6 => x"ff802608",
     7 => x"4f270000",
     8 => x"002d4f27",
     9 => x"00000029",
    10 => x"4f00fd87",
    11 => x"4fc1cefc",
    12 => x"4ec9c086",
    13 => x"c1cefc49",
    14 => x"c1c5d848",
    15 => x"89d08903",
    16 => x"c0404040",
    17 => x"40f687d0",
    18 => x"8105c050",
    19 => x"c18905f9",
    20 => x"87c1c5d5",
    21 => x"4dc1c5d5",
    22 => x"4c74ad02",
    23 => x"c487240f",
    24 => x"f787c2e1",
    25 => x"87c1c5d5",
    26 => x"4dc1c5d5",
    27 => x"4c74ad02",
    28 => x"c687c48c",
    29 => x"6c0ff587",
    30 => x"00fd870e",
    31 => x"5e5b5c0e",
    32 => x"c4c0c0c0",
    33 => x"4bc9c54c",
    34 => x"c9d7bf4a",
    35 => x"7249c18a",
    36 => x"719902cf",
    37 => x"877449c1",
    38 => x"84115372",
    39 => x"49c18a71",
    40 => x"9905f187",
    41 => x"c287264d",
    42 => x"264c264b",
    43 => x"264f1e73",
    44 => x"1e714be7",
    45 => x"48c0e050",
    46 => x"e348c850",
    47 => x"e348c650",
    48 => x"e748c0e1",
    49 => x"50734ac8",
    50 => x"b72ac4c0",
    51 => x"c0c049ca",
    52 => x"81710a97",
    53 => x"7a734ac3",
    54 => x"ff9ac4c0",
    55 => x"c0c049cb",
    56 => x"81710a97",
    57 => x"7ae748c0",
    58 => x"e050e348",
    59 => x"c850e348",
    60 => x"c050e748",
    61 => x"c0e150fe",
    62 => x"f0871e73",
    63 => x"1ec2c0c0",
    64 => x"4b730ffe",
    65 => x"e4871e73",
    66 => x"1eeb48c3",
    67 => x"ef50e748",
    68 => x"c0e050e3",
    69 => x"48c850e3",
    70 => x"48c650e7",
    71 => x"48c0e150",
    72 => x"ffc248c1",
    73 => x"9f78e748",
    74 => x"c0e050e3",
    75 => x"48c450e3",
    76 => x"48c250e7",
    77 => x"48c0e150",
    78 => x"e748c0e0",
    79 => x"50e348c8",
    80 => x"50e348c7",
    81 => x"50e748c0",
    82 => x"e150fcee",
    83 => x"87c0ffff",
    84 => x"49fdda87",
    85 => x"c0fcc04b",
    86 => x"c8d149c0",
    87 => x"f1eb87d0",
    88 => x"f9877098",
    89 => x"02c1c387",
    90 => x"c0fff04b",
    91 => x"c7fa49c0",
    92 => x"f1d787d6",
    93 => x"ec877098",
    94 => x"02c0e687",
    95 => x"c3f04bc2",
    96 => x"c0c01ec6",
    97 => x"fd49c0ee",
    98 => x"cd87c486",
    99 => x"709802c8",
   100 => x"87c3ff4b",
   101 => x"fde387d9",
   102 => x"87c7c949",
   103 => x"c0f0ea87",
   104 => x"d087c7de",
   105 => x"49c0f0e1",
   106 => x"87c787c8",
   107 => x"e749c0f0",
   108 => x"d8877349",
   109 => x"fbf787fe",
   110 => x"da87fbed",
   111 => x"87383332",
   112 => x"4f534441",
   113 => x"4442494e",
   114 => x"0043616e",
   115 => x"2774206c",
   116 => x"6f616420",
   117 => x"6669726d",
   118 => x"77617265",
   119 => x"0a00556e",
   120 => x"61626c65",
   121 => x"20746f20",
   122 => x"6c6f6361",
   123 => x"74652070",
   124 => x"61727469",
   125 => x"74696f6e",
   126 => x"0a004875",
   127 => x"6e74696e",
   128 => x"6720666f",
   129 => x"72207061",
   130 => x"72746974",
   131 => x"696f6e0a",
   132 => x"00496e69",
   133 => x"7469616c",
   134 => x"697a696e",
   135 => x"67205344",
   136 => x"20636172",
   137 => x"640a0046",
   138 => x"61696c65",
   139 => x"6420746f",
   140 => x"20696e69",
   141 => x"7469616c",
   142 => x"697a6520",
   143 => x"53442063",
   144 => x"6172640a",
   145 => x"00000000",
   146 => x"00000000",
   147 => x"0833fc0f",
   148 => x"ff00dff1",
   149 => x"8060f600",
   150 => x"0000121e",
   151 => x"e486e348",
   152 => x"c3ff50e3",
   153 => x"97bf48c4",
   154 => x"a6586e49",
   155 => x"c3ff99e3",
   156 => x"48c3ff50",
   157 => x"c831e397",
   158 => x"bf48c8a6",
   159 => x"58c46648",
   160 => x"c3ff98cc",
   161 => x"a658c866",
   162 => x"b1e348c3",
   163 => x"ff50c831",
   164 => x"e397bf48",
   165 => x"d0a658cc",
   166 => x"6648c3ff",
   167 => x"98d4a658",
   168 => x"d066b1e3",
   169 => x"48c3ff50",
   170 => x"c831e397",
   171 => x"bf48d8a6",
   172 => x"58d46648",
   173 => x"c3ff98dc",
   174 => x"a658d866",
   175 => x"b17148e4",
   176 => x"8e264f0e",
   177 => x"5e5b5c0e",
   178 => x"1e714a72",
   179 => x"49c3ff99",
   180 => x"e3099779",
   181 => x"09c1c5d8",
   182 => x"bf05c887",
   183 => x"d06648c9",
   184 => x"30d4a658",
   185 => x"d06649d8",
   186 => x"29c3ff99",
   187 => x"e3099779",
   188 => x"09d06649",
   189 => x"d029c3ff",
   190 => x"99e30997",
   191 => x"7909d066",
   192 => x"49c829c3",
   193 => x"ff99e309",
   194 => x"977909d0",
   195 => x"6649c3ff",
   196 => x"99e30997",
   197 => x"79097249",
   198 => x"d029c3ff",
   199 => x"99e30997",
   200 => x"790997bf",
   201 => x"48c4a658",
   202 => x"6e4bc3ff",
   203 => x"9bc9f0ff",
   204 => x"4cc3ffab",
   205 => x"05dc87e3",
   206 => x"48c3ff50",
   207 => x"e397bf48",
   208 => x"c4a6586e",
   209 => x"4bc3ff9b",
   210 => x"c18c02c6",
   211 => x"87c3ffab",
   212 => x"02e48773",
   213 => x"4ac4b72a",
   214 => x"c0f0a249",
   215 => x"c0e9e087",
   216 => x"734acf9a",
   217 => x"c0f0a249",
   218 => x"c0e9d487",
   219 => x"734826c2",
   220 => x"87264d26",
   221 => x"4c264b26",
   222 => x"4f1ec049",
   223 => x"e348c3ff",
   224 => x"50c181c3",
   225 => x"c8b7a904",
   226 => x"f287264f",
   227 => x"1e731ee8",
   228 => x"87c4f8df",
   229 => x"4bc01ec0",
   230 => x"fff0c1f7",
   231 => x"49fce387",
   232 => x"c486c1a8",
   233 => x"05c0e887",
   234 => x"e348c3ff",
   235 => x"50c1c0c0",
   236 => x"c0c0c01e",
   237 => x"c0e1f0c1",
   238 => x"e949fcc6",
   239 => x"87c48670",
   240 => x"9805c987",
   241 => x"e348c3ff",
   242 => x"50c148cb",
   243 => x"87fee987",
   244 => x"c18b05fe",
   245 => x"ff87c048",
   246 => x"feda8743",
   247 => x"4d443431",
   248 => x"2025640a",
   249 => x"00434d44",
   250 => x"35352025",
   251 => x"640a0043",
   252 => x"4d443431",
   253 => x"2025640a",
   254 => x"00434d44",
   255 => x"35352025",
   256 => x"640a0069",
   257 => x"6e697420",
   258 => x"25640a20",
   259 => x"2000696e",
   260 => x"69742025",
   261 => x"640a2020",
   262 => x"00436d64",
   263 => x"5f696e69",
   264 => x"740a0043",
   265 => x"4d44385f",
   266 => x"34207265",
   267 => x"73706f6e",
   268 => x"73653a20",
   269 => x"25640a00",
   270 => x"434d4435",
   271 => x"38202564",
   272 => x"0a202000",
   273 => x"434d4435",
   274 => x"385f3220",
   275 => x"25640a20",
   276 => x"2000434d",
   277 => x"44353820",
   278 => x"25640a20",
   279 => x"20005344",
   280 => x"48432049",
   281 => x"6e697469",
   282 => x"616c697a",
   283 => x"6174696f",
   284 => x"6e206572",
   285 => x"726f7221",
   286 => x"0a00636d",
   287 => x"645f434d",
   288 => x"44382072",
   289 => x"6573706f",
   290 => x"6e73653a",
   291 => x"2025640a",
   292 => x"00526561",
   293 => x"6420636f",
   294 => x"6d6d616e",
   295 => x"64206661",
   296 => x"696c6564",
   297 => x"20617420",
   298 => x"25642028",
   299 => x"2564290a",
   300 => x"001e731e",
   301 => x"e348c3ff",
   302 => x"50d0d949",
   303 => x"c0e4ca87",
   304 => x"d34bc01e",
   305 => x"c0fff0c1",
   306 => x"c149f7f6",
   307 => x"87c48670",
   308 => x"9805c987",
   309 => x"e348c3ff",
   310 => x"50c148cb",
   311 => x"87fad987",
   312 => x"c18b05ff",
   313 => x"dc87c048",
   314 => x"faca871e",
   315 => x"731e1efa",
   316 => x"c787c6ea",
   317 => x"1ec0e1f0",
   318 => x"c1c849f7",
   319 => x"c587704b",
   320 => x"731ed1fa",
   321 => x"1ec0efd3",
   322 => x"87cc86c1",
   323 => x"ab02c887",
   324 => x"fede87c0",
   325 => x"48c1ff87",
   326 => x"f5c08770",
   327 => x"49cfffff",
   328 => x"99c6eaa9",
   329 => x"02c887fe",
   330 => x"c787c048",
   331 => x"c1e887e3",
   332 => x"48c3ff50",
   333 => x"c0f14bf9",
   334 => x"d2877098",
   335 => x"02c1c687",
   336 => x"c01ec0ff",
   337 => x"f0c1fa49",
   338 => x"f5f887c4",
   339 => x"86709805",
   340 => x"c0f387e3",
   341 => x"48c3ff50",
   342 => x"e397bf48",
   343 => x"c4a6586e",
   344 => x"49c3ff99",
   345 => x"e348c3ff",
   346 => x"50e348c3",
   347 => x"ff50e348",
   348 => x"c3ff50e3",
   349 => x"48c3ff50",
   350 => x"c1c09902",
   351 => x"c487c148",
   352 => x"d587c048",
   353 => x"d187c2ab",
   354 => x"05c487c0",
   355 => x"48c887c1",
   356 => x"8b05fee2",
   357 => x"87c04826",
   358 => x"f7da871e",
   359 => x"731ec1c5",
   360 => x"d848c178",
   361 => x"eb48c3ef",
   362 => x"50c74be7",
   363 => x"48c350f7",
   364 => x"c787e748",
   365 => x"c250e348",
   366 => x"c3ff50c0",
   367 => x"1ec0e5d0",
   368 => x"c1c049f3",
   369 => x"fd87c486",
   370 => x"c1a805c2",
   371 => x"87c14bc2",
   372 => x"ab05c587",
   373 => x"c048c0f1",
   374 => x"87c18b05",
   375 => x"ffcc87fc",
   376 => x"c987c1c5",
   377 => x"dc58c1c5",
   378 => x"d8bf05cd",
   379 => x"87c11ec0",
   380 => x"fff0c1d0",
   381 => x"49f3cb87",
   382 => x"c486e348",
   383 => x"c3ff50e7",
   384 => x"48c350e3",
   385 => x"48c3ff50",
   386 => x"c148f5e8",
   387 => x"870e5e5b",
   388 => x"5c5d0e1e",
   389 => x"714ac04d",
   390 => x"e348c3ff",
   391 => x"50e748c2",
   392 => x"50eb48c7",
   393 => x"50e348c3",
   394 => x"ff50721e",
   395 => x"c0fff0c1",
   396 => x"d149f2ce",
   397 => x"87c48670",
   398 => x"9805c1c9",
   399 => x"87c5eecd",
   400 => x"df4be348",
   401 => x"c3ff50e3",
   402 => x"97bf48c4",
   403 => x"a6586e49",
   404 => x"c3ff99c3",
   405 => x"fea905de",
   406 => x"87c04cef",
   407 => x"fd87d466",
   408 => x"087808d4",
   409 => x"6648c480",
   410 => x"d8a658c1",
   411 => x"84c2c0b7",
   412 => x"ac04e787",
   413 => x"c14b4dc1",
   414 => x"8b05ffc5",
   415 => x"87e348c3",
   416 => x"ff50e748",
   417 => x"c3507548",
   418 => x"26f3e587",
   419 => x"1e731e71",
   420 => x"4b7349d8",
   421 => x"29c3ff99",
   422 => x"734ac82a",
   423 => x"cffcc09a",
   424 => x"72b1734a",
   425 => x"c832c0ff",
   426 => x"f0c0c09a",
   427 => x"72b1734a",
   428 => x"d832ffc0",
   429 => x"c0c0c09a",
   430 => x"72b17148",
   431 => x"c487264d",
   432 => x"264c264b",
   433 => x"264f1e73",
   434 => x"1e714b73",
   435 => x"49c829c3",
   436 => x"ff99734a",
   437 => x"c832cffc",
   438 => x"c09a72b1",
   439 => x"7148e287",
   440 => x"0e5e5b5c",
   441 => x"0e714bc0",
   442 => x"4cd06648",
   443 => x"c0b7a806",
   444 => x"c0e38713",
   445 => x"4acc6697",
   446 => x"bf49cc66",
   447 => x"48c180d0",
   448 => x"a65871b7",
   449 => x"aa02c487",
   450 => x"c148cc87",
   451 => x"c184d066",
   452 => x"b7ac04ff",
   453 => x"dd87c048",
   454 => x"c287264d",
   455 => x"264c264b",
   456 => x"264f0e5e",
   457 => x"5b5c0e1e",
   458 => x"c1ceda48",
   459 => x"ff78c1cd",
   460 => x"ea48c078",
   461 => x"c0eac749",
   462 => x"dacf87c1",
   463 => x"c5e21ec0",
   464 => x"49fbc987",
   465 => x"c4867098",
   466 => x"05c587c0",
   467 => x"48caf087",
   468 => x"c04bc1ce",
   469 => x"d648c178",
   470 => x"c81ec0ea",
   471 => x"d41ec1c6",
   472 => x"d849fdfb",
   473 => x"87c88670",
   474 => x"9805c687",
   475 => x"c1ced648",
   476 => x"c078c81e",
   477 => x"c0eadd1e",
   478 => x"c1c6f449",
   479 => x"fde187c8",
   480 => x"86709805",
   481 => x"c687c1ce",
   482 => x"d648c078",
   483 => x"c81ec0ea",
   484 => x"e61ec1c6",
   485 => x"f449fdc7",
   486 => x"87c88670",
   487 => x"9805c587",
   488 => x"c048c9db",
   489 => x"87c1ced6",
   490 => x"bf1ec0ea",
   491 => x"ef1ec0e4",
   492 => x"ea87c886",
   493 => x"c1ced6bf",
   494 => x"02c1ed87",
   495 => x"c1c5e24a",
   496 => x"48c6fea0",
   497 => x"4cc1cce8",
   498 => x"bf4bc1cd",
   499 => x"e09fbf49",
   500 => x"c4a65ac5",
   501 => x"d6eaa905",
   502 => x"c0cc87c8",
   503 => x"a44a6a49",
   504 => x"fae98770",
   505 => x"4bdb87c7",
   506 => x"fea2499f",
   507 => x"6949cae9",
   508 => x"d5a902c0",
   509 => x"cc87c0e8",
   510 => x"c449d7cd",
   511 => x"87c048c7",
   512 => x"fe87731e",
   513 => x"c0e8e21e",
   514 => x"c0e3d087",
   515 => x"c1c5e21e",
   516 => x"7349f7f8",
   517 => x"87cc8670",
   518 => x"9805c0c5",
   519 => x"87c048c7",
   520 => x"de87c0e8",
   521 => x"fa49d6e1",
   522 => x"87c0ebc2",
   523 => x"1ec0e2eb",
   524 => x"87c81ec0",
   525 => x"ebda1ec1",
   526 => x"c6f449fa",
   527 => x"e287cc86",
   528 => x"709805c0",
   529 => x"c987c1cd",
   530 => x"ea48c178",
   531 => x"c0e487c8",
   532 => x"1ec0ebe3",
   533 => x"1ec1c6d8",
   534 => x"49fac487",
   535 => x"c8867098",
   536 => x"02c0cf87",
   537 => x"c0e9e11e",
   538 => x"c0e1f087",
   539 => x"c486c048",
   540 => x"c6cd87c1",
   541 => x"cde097bf",
   542 => x"49c1d5a9",
   543 => x"05c0cd87",
   544 => x"c1cde197",
   545 => x"bf49c2ea",
   546 => x"a902c0c5",
   547 => x"87c048c5",
   548 => x"ee87c1c5",
   549 => x"e297bf49",
   550 => x"c3e9a902",
   551 => x"c0d287c1",
   552 => x"c5e297bf",
   553 => x"49c3eba9",
   554 => x"02c0c587",
   555 => x"c048c5cf",
   556 => x"87c1c5ed",
   557 => x"97bf4971",
   558 => x"9905c0cc",
   559 => x"87c1c5ee",
   560 => x"97bf49c2",
   561 => x"a902c0c5",
   562 => x"87c048c4",
   563 => x"f287c1c5",
   564 => x"ef97bf48",
   565 => x"c1cde658",
   566 => x"c1cde2bf",
   567 => x"48c188c1",
   568 => x"cdea58c1",
   569 => x"c5f097bf",
   570 => x"497381c1",
   571 => x"c5f197bf",
   572 => x"4ac832c1",
   573 => x"cdf64872",
   574 => x"a178c1c5",
   575 => x"f297bf48",
   576 => x"c1cece58",
   577 => x"c1cdeabf",
   578 => x"02c2e287",
   579 => x"c81ec0e9",
   580 => x"fe1ec1c6",
   581 => x"f449f7c7",
   582 => x"87c88670",
   583 => x"9802c0c5",
   584 => x"87c048c3",
   585 => x"da87c1cd",
   586 => x"e2bf48c4",
   587 => x"30c1ced2",
   588 => x"58c1cde2",
   589 => x"bf4ac1ce",
   590 => x"ca5ac1c6",
   591 => x"c797bf49",
   592 => x"c831c1c6",
   593 => x"c697bf4b",
   594 => x"73a149c1",
   595 => x"c6c897bf",
   596 => x"4bd03373",
   597 => x"a149c1c6",
   598 => x"c997bf4b",
   599 => x"d83373a1",
   600 => x"49c1ced6",
   601 => x"59c1ceca",
   602 => x"bf91c1cd",
   603 => x"f6bf81c1",
   604 => x"cdfe59c1",
   605 => x"c6cf97bf",
   606 => x"4bc833c1",
   607 => x"c6ce97bf",
   608 => x"4c74a34b",
   609 => x"c1c6d097",
   610 => x"bf4cd034",
   611 => x"74a34bc1",
   612 => x"c6d197bf",
   613 => x"4ccf9cd8",
   614 => x"3474a34b",
   615 => x"c1cec25b",
   616 => x"c28b7392",
   617 => x"c1cec248",
   618 => x"72a178c1",
   619 => x"d087c1c5",
   620 => x"f497bf49",
   621 => x"c831c1c5",
   622 => x"f397bf4a",
   623 => x"72a149c1",
   624 => x"ced259c5",
   625 => x"31c7ff81",
   626 => x"c929c1ce",
   627 => x"ca59c1c5",
   628 => x"f997bf4a",
   629 => x"c832c1c5",
   630 => x"f897bf4b",
   631 => x"73a24ac1",
   632 => x"ced65ac1",
   633 => x"cecabf92",
   634 => x"c1cdf6bf",
   635 => x"82c1cec6",
   636 => x"5ac1cdfe",
   637 => x"48c078c1",
   638 => x"cdfa4872",
   639 => x"a178c148",
   640 => x"26f4d887",
   641 => x"4e6f2070",
   642 => x"61727469",
   643 => x"74696f6e",
   644 => x"20736967",
   645 => x"6e617475",
   646 => x"72652066",
   647 => x"6f756e64",
   648 => x"0a005265",
   649 => x"6164696e",
   650 => x"6720626f",
   651 => x"6f742073",
   652 => x"6563746f",
   653 => x"72202564",
   654 => x"0a005265",
   655 => x"61642062",
   656 => x"6f6f7420",
   657 => x"73656374",
   658 => x"6f722066",
   659 => x"726f6d20",
   660 => x"66697273",
   661 => x"74207061",
   662 => x"72746974",
   663 => x"696f6e0a",
   664 => x"00556e73",
   665 => x"7570706f",
   666 => x"72746564",
   667 => x"20706172",
   668 => x"74697469",
   669 => x"6f6e2074",
   670 => x"79706521",
   671 => x"0d004641",
   672 => x"54333220",
   673 => x"20200052",
   674 => x"65616469",
   675 => x"6e67204d",
   676 => x"42520a00",
   677 => x"46415431",
   678 => x"36202020",
   679 => x"00464154",
   680 => x"33322020",
   681 => x"20004641",
   682 => x"54313220",
   683 => x"20200050",
   684 => x"61727469",
   685 => x"74696f6e",
   686 => x"636f756e",
   687 => x"74202564",
   688 => x"0a004875",
   689 => x"6e74696e",
   690 => x"6720666f",
   691 => x"72206669",
   692 => x"6c657379",
   693 => x"7374656d",
   694 => x"0a004641",
   695 => x"54333220",
   696 => x"20200046",
   697 => x"41543136",
   698 => x"20202000",
   699 => x"52656164",
   700 => x"696e6720",
   701 => x"64697265",
   702 => x"63746f72",
   703 => x"79207365",
   704 => x"63746f72",
   705 => x"2025640a",
   706 => x"0066696c",
   707 => x"65202225",
   708 => x"73222066",
   709 => x"6f756e64",
   710 => x"0d004765",
   711 => x"74464154",
   712 => x"4c696e6b",
   713 => x"20726574",
   714 => x"75726e65",
   715 => x"64202564",
   716 => x"0a004361",
   717 => x"6e277420",
   718 => x"6f70656e",
   719 => x"2025730a",
   720 => x"000e5e5b",
   721 => x"5c5d0e71",
   722 => x"4ac1cdea",
   723 => x"bf02cc87",
   724 => x"724bc7b7",
   725 => x"2b724cc1",
   726 => x"ff9cca87",
   727 => x"724bc8b7",
   728 => x"2b724cc3",
   729 => x"ff9cc1ce",
   730 => x"dabfab02",
   731 => x"de87c1c5",
   732 => x"e21ec1cd",
   733 => x"f6bf4973",
   734 => x"81ead187",
   735 => x"c4867098",
   736 => x"05c587c0",
   737 => x"48c0f687",
   738 => x"c1cede5b",
   739 => x"c1cdeabf",
   740 => x"02d98774",
   741 => x"4ac492c1",
   742 => x"c5e2826a",
   743 => x"49ebec87",
   744 => x"7049714d",
   745 => x"cfffffff",
   746 => x"ff9dd087",
   747 => x"744ac292",
   748 => x"c1c5e282",
   749 => x"9f6a49ec",
   750 => x"cc87704d",
   751 => x"7548edd9",
   752 => x"870e5e5b",
   753 => x"5c5d0ef4",
   754 => x"86714cc0",
   755 => x"4bc1ceda",
   756 => x"48ff78c1",
   757 => x"cdfebf4d",
   758 => x"c1cec2bf",
   759 => x"7ec1cdea",
   760 => x"bf02c987",
   761 => x"c1cde2bf",
   762 => x"4ac432c7",
   763 => x"87c1cec6",
   764 => x"bf4ac432",
   765 => x"c8a65ac8",
   766 => x"a648c078",
   767 => x"c46648c0",
   768 => x"a806c3cf",
   769 => x"87c86649",
   770 => x"cf9905c0",
   771 => x"e3876e1e",
   772 => x"c0ebec1e",
   773 => x"d3c587c1",
   774 => x"c5e21ecc",
   775 => x"664948c1",
   776 => x"80d0a658",
   777 => x"7149e7e4",
   778 => x"87cc86c1",
   779 => x"c5e24bc3",
   780 => x"87c0e083",
   781 => x"976b4971",
   782 => x"9902c2c5",
   783 => x"87976b49",
   784 => x"c3e5a902",
   785 => x"c1fb87cb",
   786 => x"a3499769",
   787 => x"49d89905",
   788 => x"c1ef87cb",
   789 => x"1ec0e066",
   790 => x"1e7349ea",
   791 => x"c287c886",
   792 => x"709805c1",
   793 => x"dc87dca3",
   794 => x"4a6a49e8",
   795 => x"de87704a",
   796 => x"c4a44972",
   797 => x"79daa34a",
   798 => x"9f6a49e9",
   799 => x"c887c4a6",
   800 => x"58c1cdea",
   801 => x"bf02d887",
   802 => x"d4a34a9f",
   803 => x"6a49e8f5",
   804 => x"877049c0",
   805 => x"ffff9971",
   806 => x"48d030c8",
   807 => x"a658c587",
   808 => x"c4a648c0",
   809 => x"78c4664a",
   810 => x"6e82c8a4",
   811 => x"497279c0",
   812 => x"7cdc661e",
   813 => x"c0ecc91e",
   814 => x"d0e187c8",
   815 => x"86c148c1",
   816 => x"d087c866",
   817 => x"48c180cc",
   818 => x"a658c866",
   819 => x"48c466a8",
   820 => x"04fcf187",
   821 => x"c1cdeabf",
   822 => x"02c0f487",
   823 => x"7549f9e0",
   824 => x"87704d75",
   825 => x"1ec0ecda",
   826 => x"1ecff087",
   827 => x"c8867549",
   828 => x"cfffffff",
   829 => x"f899a902",
   830 => x"d6877549",
   831 => x"c289c1cd",
   832 => x"e2bf91c1",
   833 => x"cdfabf48",
   834 => x"7180c4a6",
   835 => x"58fbe787",
   836 => x"c048f48e",
   837 => x"e8c3870e",
   838 => x"5e5b5c5d",
   839 => x"0e1e714b",
   840 => x"731ec1ce",
   841 => x"de49fad8",
   842 => x"87c48670",
   843 => x"9802c1f7",
   844 => x"87c1cee2",
   845 => x"bf49c7ff",
   846 => x"81c929c4",
   847 => x"a659c04d",
   848 => x"4c6e48c0",
   849 => x"b7a806c1",
   850 => x"ed87c1cd",
   851 => x"fabf49c1",
   852 => x"cee6bf4a",
   853 => x"c28ac1cd",
   854 => x"e2bf9272",
   855 => x"a149c1cd",
   856 => x"e6bf4a74",
   857 => x"9a72a149",
   858 => x"d4661e71",
   859 => x"49e2dd87",
   860 => x"c4867098",
   861 => x"05c587c0",
   862 => x"48c1c087",
   863 => x"c184c1cd",
   864 => x"e6bf4974",
   865 => x"9905cc87",
   866 => x"c1cee6bf",
   867 => x"49f6f187",
   868 => x"c1ceea58",
   869 => x"d46648c8",
   870 => x"c080d8a6",
   871 => x"58c1856e",
   872 => x"b7ad04fe",
   873 => x"e487cf87",
   874 => x"731ec0ec",
   875 => x"f21ecceb",
   876 => x"87c886c0",
   877 => x"48c587c1",
   878 => x"cee2bf48",
   879 => x"26e5da87",
   880 => x"1ef30997",
   881 => x"79097148",
   882 => x"264f0e5e",
   883 => x"5b5c0e71",
   884 => x"4bc04c13",
   885 => x"4a729a02",
   886 => x"cd877249",
   887 => x"e287c184",
   888 => x"134a729a",
   889 => x"05f38774",
   890 => x"48c28726",
   891 => x"4d264c26",
   892 => x"4b264f0e",
   893 => x"5e5b5c5d",
   894 => x"0efc8671",
   895 => x"4cc0e066",
   896 => x"4dc1ceea",
   897 => x"4bc07e74",
   898 => x"9c05ce87",
   899 => x"c1ceeb4b",
   900 => x"c1ceea48",
   901 => x"c0f050c1",
   902 => x"d787749c",
   903 => x"02c0ee87",
   904 => x"711e7449",
   905 => x"d8664acb",
   906 => x"c687714a",
   907 => x"2649c0fa",
   908 => x"e2821253",
   909 => x"711e721e",
   910 => x"7449dc66",
   911 => x"4acaf087",
   912 => x"704c264a",
   913 => x"2649c18d",
   914 => x"749c05ff",
   915 => x"d287c0b7",
   916 => x"ad06dd87",
   917 => x"c0e46602",
   918 => x"c587c0f0",
   919 => x"4ac387c0",
   920 => x"e04a730a",
   921 => x"977a0ac1",
   922 => x"838dc0b7",
   923 => x"ad01ffe3",
   924 => x"87c1ceea",
   925 => x"ab02de87",
   926 => x"d8664cdc",
   927 => x"661ec18b",
   928 => x"976b4974",
   929 => x"0fc4866e",
   930 => x"48c180c4",
   931 => x"a658c1ce",
   932 => x"eaab05ff",
   933 => x"e5876e48",
   934 => x"fc8e264d",
   935 => x"264c264b",
   936 => x"264f3031",
   937 => x"32333435",
   938 => x"36373839",
   939 => x"41424344",
   940 => x"4546000e",
   941 => x"5e5b5c5d",
   942 => x"0e714bff",
   943 => x"4d134c74",
   944 => x"9c02d887",
   945 => x"c185d466",
   946 => x"1e7449d4",
   947 => x"660fc486",
   948 => x"74a805c7",
   949 => x"87134c74",
   950 => x"9c05e887",
   951 => x"7548264d",
   952 => x"264c264b",
   953 => x"264f0e5e",
   954 => x"5b5c5d0e",
   955 => x"e886c4a6",
   956 => x"59c0e866",
   957 => x"4bc04dc8",
   958 => x"a648c078",
   959 => x"6e97bf4c",
   960 => x"6e48c180",
   961 => x"c4a65874",
   962 => x"9c02c7c3",
   963 => x"87c86602",
   964 => x"c6cb87cc",
   965 => x"a648c078",
   966 => x"fc80c078",
   967 => x"744ac0e0",
   968 => x"8a02c3e2",
   969 => x"87c38a02",
   970 => x"c3dc87c2",
   971 => x"8a02c3c0",
   972 => x"87c28a02",
   973 => x"c3d087c4",
   974 => x"8a02c3ca",
   975 => x"87c28a02",
   976 => x"c3c487c3",
   977 => x"8a02c3ca",
   978 => x"87d48a02",
   979 => x"c0f687d4",
   980 => x"8a02c1c8",
   981 => x"87ca8a02",
   982 => x"c0f687c1",
   983 => x"8a02c1f5",
   984 => x"87c18a02",
   985 => x"df87c88a",
   986 => x"02c1de87",
   987 => x"c48a02c0",
   988 => x"eb87c38a",
   989 => x"02c0f187",
   990 => x"c28a02c8",
   991 => x"87c38a02",
   992 => x"db87c2de",
   993 => x"87cca648",
   994 => x"ca78c0ec",
   995 => x"a65bc2fa",
   996 => x"87cca648",
   997 => x"c278c0ec",
   998 => x"a65bc2ee",
   999 => x"87cca648",
  1000 => x"d078c0ec",
  1001 => x"a65bc2e2",
  1002 => x"87c0f066",
  1003 => x"1ec0f066",
  1004 => x"1ec48373",
  1005 => x"4ac48a6a",
  1006 => x"49fbf787",
  1007 => x"c886704a",
  1008 => x"72a54dc0",
  1009 => x"eca65bc2",
  1010 => x"c187c8a6",
  1011 => x"48c178c0",
  1012 => x"eca65bc1",
  1013 => x"f587c0f0",
  1014 => x"661ec483",
  1015 => x"734ac48a",
  1016 => x"6a49c0f0",
  1017 => x"660fc486",
  1018 => x"c185c0ec",
  1019 => x"a65bc1da",
  1020 => x"87c0f066",
  1021 => x"1ec0e549",
  1022 => x"c0f0660f",
  1023 => x"c486c185",
  1024 => x"c0eca65b",
  1025 => x"c1c487c8",
  1026 => x"a648c178",
  1027 => x"c0eca65b",
  1028 => x"c0f887d0",
  1029 => x"a648c178",
  1030 => x"f880c178",
  1031 => x"c0eca65b",
  1032 => x"c0e887c0",
  1033 => x"eca65bc0",
  1034 => x"f0ac06de",
  1035 => x"87c0eca6",
  1036 => x"5bc0f9ac",
  1037 => x"03d487d4",
  1038 => x"664aca92",
  1039 => x"744bc0f0",
  1040 => x"8bd4a648",
  1041 => x"73a278f4",
  1042 => x"80c178c0",
  1043 => x"e8664bcc",
  1044 => x"6602c1ea",
  1045 => x"87c48373",
  1046 => x"4ac48aa6",
  1047 => x"486a78c1",
  1048 => x"e4ac05d8",
  1049 => x"87c46648",
  1050 => x"c0b7a803",
  1051 => x"cf87c0ed",
  1052 => x"49f5cc87",
  1053 => x"c46648c0",
  1054 => x"0888c8a6",
  1055 => x"58d0661e",
  1056 => x"d8661ec0",
  1057 => x"f8661ec0",
  1058 => x"f8661edc",
  1059 => x"661ed866",
  1060 => x"49f5df87",
  1061 => x"d486704a",
  1062 => x"72a54dc0",
  1063 => x"e187c0e5",
  1064 => x"ac05cf87",
  1065 => x"d0a648c0",
  1066 => x"78c480c0",
  1067 => x"78f480c1",
  1068 => x"78cc87c0",
  1069 => x"f0661e74",
  1070 => x"49c0f066",
  1071 => x"0fc4866e",
  1072 => x"97bf4c6e",
  1073 => x"48c180c4",
  1074 => x"a658749c",
  1075 => x"05f8fd87",
  1076 => x"7548e88e",
  1077 => x"264d264c",
  1078 => x"264b264f",
  1079 => x"1ec01ec0",
  1080 => x"f7c01ed0",
  1081 => x"a61ed066",
  1082 => x"49f7fa87",
  1083 => x"f48e264f",
  1084 => x"1e731e72",
  1085 => x"9a02c0e7",
  1086 => x"87c048c1",
  1087 => x"4b72a906",
  1088 => x"d1877282",
  1089 => x"06c98773",
  1090 => x"8372a901",
  1091 => x"f487c387",
  1092 => x"c1b23a72",
  1093 => x"a9038973",
  1094 => x"8007c12a",
  1095 => x"2b05f387",
  1096 => x"264b264f",
  1097 => x"1e751ec4",
  1098 => x"4d71b7a1",
  1099 => x"04ffb9c1",
  1100 => x"81c3bd07",
  1101 => x"72b7a204",
  1102 => x"ffbac182",
  1103 => x"c1bd07fe",
  1104 => x"ee87c12d",
  1105 => x"04ffb8c1",
  1106 => x"80072d04",
  1107 => x"ffb9c181",
  1108 => x"07264d26",
  1109 => x"4f264d26",
  others => ( x"00000000")
);

-- Xilinx Vivado attributes
attribute ram_style: string;
attribute ram_style of ram: signal is "block";

signal wea : std_logic_vector(NB_COL - 1 downto 0);
signal web : std_logic_vector(NB_COL - 1 downto 0);

begin
    
    -- Generate write enable signals
    -- The Block ram generator doesn't like it when the compare is done in the if statement it self.
    
    
    wea <= bytesel(0) & bytesel(1) & bytesel(2) & bytesel(3) when we = '1' else (others => '0');
    web <= bytesel2(0) & bytesel2(1) & bytesel2(2) & bytesel2(3) when we2 = '1' else (others => '0');

    ------- Port A -------
    process(clk)
    begin
        if rising_edge(clk) then
            q <= ram(to_integer(unsigned(addr)));
            for i in 0 to NB_COL - 1 loop
                if (wea(i) = '1') then
                    ram(to_integer(unsigned(addr)))((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH) <= d((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH);
                end if;
            end loop;
        end if;
    end process;

    ------- Port B -------
    process(clk)
    begin
        if rising_edge(clk) then
            q2 <= ram(to_integer(unsigned(addr2)));
            for i in 0 to NB_COL - 1 loop
                if (web(i) = '1') then
                    ram(to_integer(unsigned(addr2)))((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH) <= d2((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH);
                end if;
            end loop;
        end if;
    end process;

end arch;
