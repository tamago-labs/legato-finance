
import axios from "axios"
import type { Schema } from "../amplify/data/resource"
import { generateClient } from "aws-amplify/api"

const client = generateClient<Schema>()


const useAI = () => {

    const query = async (messages: any) => {

        const tools: any = getUserTools()

        const result: any = await client.queries.Chat({
            messages: JSON.stringify(messages),
            tools: JSON.stringify(tools)
        })

        return JSON.parse(result.data)
    }

    const parse = async (messages: any) => {
        const result: any = await client.queries.WeightAssignment({
            messages: JSON.stringify(messages)
        })

        return JSON.parse(result.data)
    }

    const getUserTools = () => {
        return [{
            "type": "function",
            "function": {
                "name": "create_outcome",
                "description": "Create a new outcome with a title and the resolution date.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "title": {
                            "type": "string",
                            "description": "Outcome title."
                        },
                        "resolutionDate": {
                            "type": "string",
                            "description": "Outcome resolution date."
                        }
                    },
                    "required": [
                        "title",
                        "resolutionDate"
                    ],
                    "additionalProperties": false
                },
                "strict": true
            }
        },
        {
            "type": "function",
            "function": {
                "name": "place_bet",
                "description": "Place a bet with the round ID and outcome ID.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "roundId": {
                            "type": "number",
                            "description": "Round ID."
                        },
                        "outcomeId": {
                            "type": "number",
                            "description": "Outcome ID."
                        }
                    },
                    "required": [
                        "roundId",
                        "outcomeId"
                    ],
                    "additionalProperties": false
                },
                "strict": true
            }
        }
        ];
    }

    const query2 = async (messages: any, roundNumber: any, period: any) => {

        // const tools: any = getUserTools()
 
        // const result: any = await axios.post("/api/query", {
        //     messages,
        //     tools,
        //     roundNumber,
        //     period
        // })

        const result: any = await client.queries.Chat2({
            messages: JSON.stringify(messages),
            roundNumber: `${roundNumber}`,
            period: `${period}`
        })

        // return result.data
        return JSON.parse(result.data)
    }

    return {
        query,
        parse,
        query2
    }
}

export default useAI