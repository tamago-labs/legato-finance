
import { Tab, TabGroup, TabList, TabPanel, TabPanels } from '@headlessui/react'
import { useEffect, useState, useCallback } from "react"
import Alert from "../../../components/Alert"
import FaucetModal from "../../../modals/faucet"
import AllOutcomes from "./AllOutcomes"
import ChatPanel from "./ChatPanel"
import Overview from "./Overview"
import Ranking from "./Ranking"
import System from "./System"
import WalletPanel from "./WalletPanel"
import useAptos from '@/hooks/useAptos'
import useDatabase from '@/hooks/useDatabase'
import { ArrowLeft, ArrowRight } from "react-feather"
import AvailableBets from './AvailableBets'
import PlaceBetModal from "../../../modals/placeBet"
import MyBetPositions from './MyBetPositions'

// Fixed on this version
const MARKET_ID = 1

const MarketDetails = () => {

    const [modal, setModal] = useState(false)

    const { getMarketInfo } = useAptos()
    const { getMarketData } = useDatabase()

    const [marketData, setMarketData] = useState<any>()
    const [onchainMarket, setOnchainMarket] = useState<any>()
    const [bet, setBet] = useState<any>(undefined) 

    useEffect(() => {
        getMarketInfo(MARKET_ID).then(setOnchainMarket)
    }, [])

    useEffect(() => {
        getMarketData(MARKET_ID).then(setMarketData)
    }, [])

    const openBetModal = (entry: any) => {
        setBet(entry)
    }

    const currentRound = onchainMarket ? onchainMarket.round : 0

    return (
        <>

            <FaucetModal
                visible={modal}
                close={() => setModal(false)}
            />

            <PlaceBetModal
                visible={bet}
                close={() => setBet(undefined)}
                bet={bet}
            />

            <TabGroup className=" grid grid-cols-1 sm:grid-cols-5 gap-3">

                <div className="col-span-5 mb-2">
                    <Alert>
                        <div className="text-xs sm:text-base">
                            This new version is currently live at Aptos Testnet and uses Mock USDC, which you can get from the <span onClick={() => setModal(true)} className="underline cursor-pointer" >Faucet</span>
                        </div>
                    </Alert>
                </div>

                <div className="col-span-3 flex flex-col ">

                    <Overview
                        market={{
                            ...onchainMarket
                        }}
                    />

                    <TabList className="flex gap-3 mt-2.5">
                        {["💬 Chat", "🎯 Available Outcomes", "⚡ My Positions"].map((name) => (
                            <Tab
                                key={name}
                                className="rounded-lg cursor-pointer py-2 px-6 text-base  text-white border border-gray/30  focus:outline-none data-[selected]:bg-[#141F32] data-[hover]:bg-[#141F32] data-[selected]:data-[hover]:bg-[#141F32] data-[focus]:outline-1 data-[focus]:outline-white"
                            >
                                {name}
                            </Tab>
                        ))}
                    </TabList>


                </div>

                <div className="col-span-2 flex flex-col h-full  ">

                    <Ranking
                        currentRound={currentRound}
                        marketData={marketData}
                    />

                </div>

                <div className="col-span-5">

                    <TabPanels className="mt-2 h-full ">
                        <TabPanel >
                            <ChatPanel
                                currentRound={currentRound}
                                marketData={marketData}
                                onchainMarket={onchainMarket}
                                openBetModal={openBetModal}
                            />

                        </TabPanel>
                        <TabPanel >

                            <AvailableBets
                                currentRound={currentRound}
                                marketData={marketData}
                                onchainMarket={onchainMarket}
                                openBetModal={openBetModal} 
                            />
                        </TabPanel>
                        <TabPanel >

                            <MyBetPositions
                                marketData={marketData}
                            />

                        </TabPanel>

                    </TabPanels>

                </div>



            </TabGroup>
        </>
    )
}

export default MarketDetails