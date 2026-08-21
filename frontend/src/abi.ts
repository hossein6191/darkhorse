export const darkHorseAbi = [
  {
    type: "function",
    name: "marketCount",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "createMarket",
    inputs: [
      { name: "question", type: "string" },
      { name: "closeTime", type: "uint64" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "placeBet",
    inputs: [
      { name: "marketId", type: "uint256" },
      { name: "sideCiphertext", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "resolve",
    inputs: [
      { name: "marketId", type: "uint256" },
      { name: "yesWon", type: "bool" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "cancel",
    inputs: [{ name: "marketId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "submitWinningTotal",
    inputs: [
      { name: "marketId", type: "uint256" },
      {
        name: "decryption",
        type: "tuple",
        components: [
          { name: "handle", type: "bytes32" },
          { name: "value", type: "bytes32" },
        ],
      },
      { name: "signatures", type: "bytes[]" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "prepareClaim",
    inputs: [{ name: "marketId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "claim",
    inputs: [
      { name: "marketId", type: "uint256" },
      {
        name: "decryption",
        type: "tuple",
        components: [
          { name: "handle", type: "bytes32" },
          { name: "value", type: "bytes32" },
        ],
      },
      { name: "signatures", type: "bytes[]" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "refund",
    inputs: [{ name: "marketId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "getMarket",
    inputs: [{ name: "marketId", type: "uint256" }],
    outputs: [
      { name: "question", type: "string" },
      { name: "resolver", type: "address" },
      { name: "closeTime", type: "uint64" },
      { name: "outcome", type: "uint8" },
      { name: "pot", type: "uint256" },
      { name: "totalYesHandle", type: "bytes32" },
      { name: "totalNoHandle", type: "bytes32" },
      { name: "winningTotal", type: "uint256" },
      { name: "totalsSubmitted", type: "bool" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "stakeOf",
    inputs: [
      { name: "", type: "uint256" },
      { name: "", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "claimed",
    inputs: [
      { name: "", type: "uint256" },
      { name: "", type: "address" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "sideHandleOf",
    inputs: [
      { name: "marketId", type: "uint256" },
      { name: "bettor", type: "address" },
    ],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "winStakeHandleOf",
    inputs: [
      { name: "marketId", type: "uint256" },
      { name: "bettor", type: "address" },
    ],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
] as const;

export const getFeeAbi = [
  {
    type: "function",
    name: "getFee",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "pure",
  },
] as const;
