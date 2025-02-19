import { ArrowRight } from "react-feather"


import Link from "next/link"

const MarketCard = () => {


    return (
        <Link href="/markets/coinmarketcap">
            <div className="flex flex-col group cursor-pointer">
            <div  className={`  bg-black bg-gradient-to-b  from-white/[0.03]  to-transparent hidden  md:flex flex-row rounded-lg  overflow-hidden  border  border-gray/30   h-[90px]  `} >
                <img src={"./assets/images/coinmarketcap.png"} className="h-full scale-125 rotate-6" alt="" />

                <h3 className="text-xl text-white font-semibold my-auto ml-[40px]">CoinMarketCap.com</h3>
                <p className="my-auto px-4 ml-2 text-sm  lg:text-base">
                Predict anything listed on the website from top token prices to market trends and trading volumes
                </p>

                <div className=" flex ml-auto px-4  ">
                    <div className="text-secondary p-2 uppercase font-semibold text-sm flex flex-row m-auto">
                        <ArrowRight size={24} className="duration-300 ml-0.5 group-hover:translate-x-2 rtl:rotate-180 text-secondary rtl:group-hover:-translate-x-2" />
                    </div>
                </div>
            </div>

            <div className={`  bg-black bg-gradient-to-b  from-white/[0.03]  to-transparent flex  md:hidden flex-row rounded  overflow-hidden  border  border-gray/30   h-[90px]  `} >
                <img src={"./assets/images/coinmarketcap.png"} className="h-full scale-125 rotate-6  " alt="" />

                <div className="flex flex-col py-2">
                    <h3 className="text-base sm:text-lg text-white font-semibold mb-0.5 ml-[30px] sm:ml-[40px]">CoinMarketCap.com</h3>
                    <p className="  line-clamp-3 leading-3  text-xs ml-[30px] lg:text-sm">
                        Predict anything listed on the 1st page from top token prices to market trends and trading volumes
                    </p>


                </div>


            </div>

        </div>
        </Link>
        
    )
}

export default MarketCard