import type { Handler } from 'aws-lambda';
import type { EventBridgeHandler } from "aws-lambda";
import type { Schema } from '../../data/resource';
import { Amplify } from 'aws-amplify';
import { generateClient } from 'aws-amplify/data';
import { getAmplifyDataClientConfig } from '@aws-amplify/backend/function/runtime';
import { env } from '$amplify/env/scheduler';
import {
  Account,
  Aptos,
  AptosConfig,
  Network,
  Ed25519PrivateKey,
  InputViewFunctionData
} from "@aptos-labs/ts-sdk";

const { resourceConfig, libraryOptions } = await getAmplifyDataClientConfig(env);

Amplify.configure(resourceConfig, libraryOptions);

const client = generateClient<Schema>();

const MARKET_ID = 1

export const handler: EventBridgeHandler<"Scheduled Event", null, void> = async (event) => {
  console.log("event", JSON.stringify(event, null, 2))

  // Checking all rounds to be updated
  const config = new AptosConfig({ network: Network.TESTNET });
  const aptos = new Aptos(config);

  const privateKey = new Ed25519PrivateKey(
    `${env.APTOS_MANAGED_KEY}`
  );

  const currentRound: number = await getOnchainCurrentRound(aptos)
  const market: any = await getMarket(MARKET_ID)
  const rounds = await market.rounds()

  for (let round of rounds.data) {

    const roundId = round.onchainId

    console.log("Checking Round:", roundId)

  }

}


const getMarket = async (marketId = 1) => {
  const markets = await client.models.Market.list({
    filter: {
      onchainId: {
        eq: marketId
      }
    }
  })
  return markets && markets.data[0] ? markets.data[0] : undefined
}

const getOnchainCurrentRound = async (aptos: any) => {

  const payload: InputViewFunctionData = {
    function: `0xab3922ccb1794928abed8f5a5e8d9dac72fed24f88077e46593bed47dcdb7775::generalized::get_market_data`,
    functionArguments: [
      MARKET_ID
    ],
  };

  const result = await aptos.view({ payload });

  const entry = {
    createdTime: result[2],
    interval: result[3]
  }

  const diff = (new Date().valueOf()) - (Number(entry.createdTime) * 1000)
  const interval = Number(entry.interval) * 1000
  const round = Math.floor(diff / interval) + 1

  console.log("Current Round: ", round)
  return round
}
