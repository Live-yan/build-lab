# coding=utf-8
import sys
import time
import os
import traceback
from ctypes import *

from NetSDK.NetSDK import NetClient
from NetSDK.SDK_Callback import *
from NetSDK.SDK_Enum import *
from NetSDK.SDK_Struct import *

global my_demo

@CB_FUNCTYPE(None, C_LLONG, POINTER(NET_RADIOMETRY_DATA), c_int, C_LDWORD)
def RadiometryCallBack(lAttachHandle, pBuf, nBufLen, dwUser):
    if lAttachHandle == my_demo.attachHandle:
        print("温度分布数据状态回调成功(The temperature distribution data status callback is successful).")
        data = cast(pBuf, POINTER(NET_RADIOMETRY_DATA)).contents
        #print(id(data.pbDataBuf))
        print("数据缓冲区大小(data buffer len): %d." % data.dwBufSize)
        my_demo.parsedata(data, nBufLen, dwUser)

class ConsoleDemo:
    def __init__(self):

        # NetSDK用到的相关变量和回调
        self.loginID = C_LLONG()
        self.playID = C_LLONG()
        self.freePort = c_int()
        self.m_DisConnectCallBack = fDisConnect(self.DisConnectCallBack)
        self.m_ReConnectCallBack = fHaveReConnect(self.ReConnectCallBack)

        # 获取NetSDK对象并初始化
        self.sdk = NetClient()
        self.sdk.InitEx(self.m_DisConnectCallBack)
        self.sdk.SetAutoReconnect(self.m_ReConnectCallBack)

        # 温度分布订阅句柄
        self.attachHandle = 0

        self.ip = ''
        self.port = 0
        self.username = ''
        self.password = ''

    def get_login_info(self):
        print("请输入登录信息(Please input login info)")
        print("")
        self.ip = input('地址(IP address):')
        self.port = int(input('端口(port):'))
        self.username = input('用户名(username):')
        self.password = input('密码(password):')
       

    def login(self):
        if not self.loginID:
            stuInParam = NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY()
            stuInParam.dwSize = sizeof(NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY)
            stuInParam.szIP = self.ip.encode()
            stuInParam.nPort = self.port
            stuInParam.szUserName = self.username.encode()
            stuInParam.szPassword = self.password.encode()
            stuInParam.emSpecCap = EM_LOGIN_SPAC_CAP_TYPE.TCP
            stuInParam.pCapParam = None

            stuOutParam = NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY()
            stuOutParam.dwSize = sizeof(NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY)

            self.loginID, device_info, error_msg = self.sdk.LoginWithHighLevelSecurity(stuInParam, stuOutParam)
            if self.loginID != 0:
                print("登录成功(Login succeed). 通道数量(Channel num):" + str(device_info.nChanNum))
                return True
            else:
                print("登录失败(Login failed). " + error_msg)
                return False

    def logout(self):
        if self.loginID:
            if self.playID:
                self.sdk.StopRealPlayEx(self.playID)
                self.playID = 0
            if self.attachHandle:
                self.sdk.RadiometryDetach(self.attachHandle)
                self.attachHandle = 0
            self.sdk.Logout(self.loginID)
            self.loginID = 0
        print("登出成功(Logout succeed)")

    # 实现断线回调函数功能
    def DisConnectCallBack(self, lLoginID, pchDVRIP, nDVRPort, dwUser):
        print("设备(Device)-离线(OffLine)")

    # 实现断线重连回调函数功能
    def ReConnectCallBack(self, lLoginID, pchDVRIP, nDVRPort, dwUser):
        print("设备(Device)-在线(OnLine)")

    # 关闭主窗口时清理资源
    def quit_demo(self):
        if self.loginID:
            self.sdk.Logout(self.loginID)
        self.sdk.Cleanup()
        print("程序结束(Demo finish)")

    def log_open(self):
        log_info = LOG_SET_PRINT_INFO()
        log_info.dwSize = sizeof(LOG_SET_PRINT_INFO)
        log_info.bSetFilePath = 1
        log_info.szLogFilePath = os.path.join(os.getcwd(), 'sdk_log.log').encode('gbk')
        result = self.sdk.LogOpen(log_info)

    def query_dev_info(self, type):
        if type == 0:
            inGetTemper = NET_IN_RADIOMETRY_GETTEMPER()
            inGetTemper.dwSize = sizeof(NET_IN_RADIOMETRY_GETTEMPER)
            inGetTemper.stCondition = NET_RADIOMETRY_CONDITION()
            inGetTemper.stCondition.nPresetId = int(input("请输入预置点编号(Please enter the preset number):"))
            inGetTemper.stCondition.nRuleId = int(input("请输入规则编号(Please enter the rule number):"))
            inGetTemper.stCondition.nMeterType = 3
            inGetTemper.stCondition.szName = str.encode(input("请输入规则名称(Please enter the rule name):"))
            inGetTemper.stCondition.nChannel = 1
            outGetTemper = NET_OUT_RADIOMETRY_GETTEMPER()
            outGetTemper.dwSize = sizeof(NET_OUT_RADIOMETRY_GETTEMPER)
            result = self.sdk.QueryDevInfo(self.loginID, EM_QUERY_DEV_INFO_TYPE.RADIOMETRY_TEMPER, inGetTemper, outGetTemper, None, 5000)
            if result:
                print("获取测温参数成功（QueryDevInfo succeed).")
                print("温度(temperature):%.2f; 温度异常(Maximum temperature):%.2f;温度异常(lowest temperature):%.2f" % (outGetTemper.stTempInfo.fTemperAver, outGetTemper.stTempInfo.fTemperMax, outGetTemper.stTempInfo.fTemperMin))
                return True
            else:
                print("获取测温参数失败（QueryDevInfo failed)." + str(self.sdk.GetLastError()))
        elif type == 1:
            inTemper = NET_IN_RADIOMETRY_GETPOINTTEMPER()
            inTemper.dwSize = sizeof(NET_IN_RADIOMETRY_GETPOINTTEMPER)
            inTemper.nChannel = 1
            inTemper.stCoordinate.nx = int(input("请输入测温点X坐标,0-8192(Please enter the X coordinate of the point, 0-8192):"))
            inTemper.stCoordinate.ny = int(input("请输入测温点Y坐标,0-8192(Please enter the Y coordinate of the point, 0-8192):"))
            outTemper = NET_OUT_RADIOMETRY_GETPOINTTEMPER()
            outTemper.dwSize = sizeof(NET_OUT_RADIOMETRY_GETPOINTTEMPER)
            result = self.sdk.QueryDevInfo(self.loginID, EM_QUERY_DEV_INFO_TYPE.POINT_TEMPER, inTemper, outTemper, None, 5000)
            if result:
                print("获取测温参数成功（QueryDevInfo succeed).")
                print("点温度(temperature):%.2f" % (outTemper.stPointTempInfo.fTemperAver))
                return True
            else:
                print("获取测温参数失败（QueryDevInfo failed)." + str(self.sdk.GetLastError()))
        return False

    def Radiometry_Attach(self):
        # 订阅温度分布数据; Subscribe to temperature distribution data
        inParam = NET_IN_RADIOMETRY_ATTACH()
        inParam.dwSize = sizeof(NET_IN_RADIOMETRY_ATTACH)
        channel = 1 # 通道订阅; channels
        inParam.nChannel = channel   # 通道订阅; channels
        inParam.cbNotify = RadiometryCallBack
        outParam = NET_OUT_RADIOMETRY_ATTACH()
        outParam.dwSize = sizeof(NET_OUT_RADIOMETRY_ATTACH)
        result = self.sdk.RadiometryAttach(self.loginID, inParam, outParam, 5000)
        if result:
            print("订阅成功（Subscribe succeed).attachHandle:%d,%x" % (result, result))
            self.attachHandle = result
            print("开始获取热图数据(Start getting heat map data)")
            inFetch = NET_IN_RADIOMETRY_FETCH()
            inFetch.dwSize = sizeof(NET_IN_RADIOMETRY_FETCH)
            inFetch.nChannel = channel
            outFetch = NET_OUT_RADIOMETRY_FETCH()
            outFetch.dwSize = sizeof(NET_OUT_RADIOMETRY_FETCH)
            result = self.sdk.RadiometryFetch(self.loginID, inFetch, outFetch, 5000)
            if result:
                print("启动热图获取成功（start getting heat map succeed).status:%d"% outFetch.nStatus)
                return True
            else:
                print("启动热图获取失败（start getting heat map fail)." + self.sdk.GetLastErrorMessage())
        else:
            print("订阅失败（Subscribe failed) " + self.sdk.GetLastErrorMessage())
        return False

    def parsedata(self, data, nBufLen, dwUser):
        try:
            size = data.stMetaData.nHeight * data.stMetaData.nWidth
            print("pixel size:%d, nHeight:%d, nWidth:%d" % (size, data.stMetaData.nHeight, data.stMetaData.nWidth))
            pGrayImg = (c_short * size)()
            pTempForPixels = (c_float * size)()
            result = self.sdk.RadiometryDataParse(data, pGrayImg, pTempForPixels)
            if result:
                print("解析成功（parse succeed).")
                #pDll = windll.LoadLibrary("./ImageAlg_win32.dll") # windows 平台动态库加载
                # pDll = cdll.LoadLibrary("./ImageAlg.so") # linux/arm 平台动态库加载
                yData = (c_char * size)()
                lut = (c_short)()
                self.sdk.drcTable(pGrayImg, data.stMetaData.nWidth, data.stMetaData.nHeight, yData, lut)
                with open('./data', 'wb+') as f:
                    f.write(yData)
                # for temp in pTempForPixels:
                #     print("像素温度(pixel temperature)%.2f" % temp)
                return True
            else:
                print("解析失败（parse fail)." + self.sdk.GetLastErrorMessage())
            return False
        except Exception as e:
            print("except")
            traceback.print_exc()
            return False

    def RuleConfig(self):
        # 测温规则设置;Temperature rule configuration
        out_buffer = (c_char * 102400)()
        channel = 1
        error = 0
        timeout = 5000
        result = self.sdk.GetNewDevConfig(self.loginID, CFG_CMD_TYPE.THERMOMETRY_RULE, channel, out_buffer, 102400,
                                          error, timeout)
        if result:
            print("获取成功(Get succeed).")
            info = CFG_RADIOMETRY_RULE_INFO()
            result = self.sdk.ParseData(CFG_CMD_TYPE.THERMOMETRY_RULE, out_buffer, info, sizeof(CFG_RADIOMETRY_RULE_INFO), None)
            if result:
                print("解析成功(ParseData succeed).")
                print("rule number:%d" % info.nCount)
                if info.nCount > 0:
                    print("nPresetId:%d; nRuleId:%d; nCoordinateCnt:%d; fObjectEmissivity:%.2f"
                          % (info.stRule[0].nPresetId, info.stRule[0].nRuleId,
                             info.stRule[0].nCoordinateCnt, info.stRule[0].stLocalParameters.fObjectEmissivity))
                    # 这里默认是矩形区域(4个测温点坐标) 如果有其他测温模式(nMeterType); 下面的测温点坐标个数将不一样
                    info.stRule[0].stCoordinates[0].nX = int(input("first point X:"))
                    info.stRule[0].stCoordinates[0].nY = int(input("first point Y:"))
                    info.stRule[0].stCoordinates[1].nX = int(input("second point X:"))
                    info.stRule[0].stCoordinates[1].nY = int(input("second point Y:"))
                    info.stRule[0].stCoordinates[2].nX = int(input("third point X:"))
                    info.stRule[0].stCoordinates[2].nY = int(input("third point Y:"))
                    info.stRule[0].stCoordinates[3].nX = int(input("fourth point X:"))
                    info.stRule[0].stCoordinates[3].nY = int(input("fourth point Y:"))
                    info.stRule[0].stLocalParameters.fObjectEmissivity = 0.55 # 辐射系数

                    in_buffer = (c_char * 102400)()
                    result = self.sdk.PacketData(CFG_CMD_TYPE.THERMOMETRY_RULE, info, sizeof(CFG_RADIOMETRY_RULE_INFO), in_buffer, 102400)
                    if result:
                        print("打包成功（PacketData success).")
                        set_error = 0
                        set_restart = 0
                        result = self.sdk.SetNewDevConfig(self.loginID, CFG_CMD_TYPE.THERMOMETRY_RULE, channel, in_buffer,
                                                          102400, set_error, set_restart, timeout)
                        if result:
                            print("设置成功(Set THERMOMETRY_RULE success).")
                            return True
                        else:
                            print("设置失败(Set THERMOMETRY_RULE failed)." + self.sdk.GetLastErrorMessage())
                            return False
                    else:
                        print("打包失败(PacketData fail). " + self.sdk.GetLastErrorMessage())
                        return False
                else:
                    print("没有测温规则; No Temperature rules")
                    return False
            else:
                print("解析失败(Parse fail). " + self.sdk.GetLastErrorMessage())
                return False
        else:
            print("获取失败(Get fail). " + self.sdk.GetLastErrorMessage())
            return False

    def GetRandomRegionTemper(self):
        inGetTemper = NET_IN_RADIOMETRY_RANDOM_REGION_TEMPER()
        inGetTemper.dwSize = sizeof(NET_IN_RADIOMETRY_RANDOM_REGION_TEMPER)
        inGetTemper.nChannel = int(input("请输入通道号(Please enter the channel):"))
        inGetTemper.nPointNum = 4
        inGetTemper.stuPolygon[0].nx = 0
        inGetTemper.stuPolygon[0].ny = 0
        inGetTemper.stuPolygon[1].nx = 0
        inGetTemper.stuPolygon[1].ny = 8191
        inGetTemper.stuPolygon[2].nx = 8191
        inGetTemper.stuPolygon[2].ny = 0
        inGetTemper.stuPolygon[3].nx = 8191
        inGetTemper.stuPolygon[3].ny = 8191

        outGetTemper = NET_OUT_RADIOMETRY_RANDOM_REGION_TEMPER()
        outGetTemper.dwSize = sizeof(NET_OUT_RADIOMETRY_RANDOM_REGION_TEMPER)
        result = self.sdk.RadiometryGetRandomRegionTemper(self.loginID, inGetTemper, outGetTemper, 5000)
        if result:
            print("获取测温区域的参数值（RadiometryGetRandomRegionTemper succeed).")
            if outGetTemper.stuRegionTempInfo.emTemperatureUnit == EM_TEMPERATURE_UNIT.EM_TEMPERATURE_CENTIGRADE:
                print("温度单位:Centigrade")
            if outGetTemper.stuRegionTempInfo.emTemperatureUnit == EM_TEMPERATURE_UNIT.EM_TEMPERATURE_FAHRENHEIT:
                print("温度单位:Fahrenheit")
            if outGetTemper.stuRegionTempInfo.emTemperatureUnit == EM_TEMPERATURE_UNIT.EM_TEMPERATURE_UNKNOWN:
                print("温度单位:unknown")
            print("平均温度(temperature):%.2f; 最高温度(Maximum temperature):%.2f;最底温度(lowest temperature):%.2f" % (outGetTemper.stuRegionTempInfo.nTemperAver/100, outGetTemper.stuRegionTempInfo.nTemperMax/100, outGetTemper.stuRegionTempInfo.nTemperMin/100))
            print("最高温度坐标: %d,%d" %(outGetTemper.stuRegionTempInfo.stuTemperMaxPoint.nx, outGetTemper.stuRegionTempInfo.stuTemperMaxPoint.ny))
            print("最低温度坐标: %d,%d" % (outGetTemper.stuRegionTempInfo.stuTemperMinPoint.nx, outGetTemper.stuRegionTempInfo.stuTemperMinPoint.ny))
            return True
        else:
            print("获取测温区域的参数值（RadiometryGetRandomRegionTemper failed)." + str(self.sdk.GetLastError()))
            return False

    def GetHeatMapsDirectly(self):
        inGetTemper = NET_IN_GET_HEATMAPS_INFO()
        inGetTemper.dwSize = sizeof(NET_IN_GET_HEATMAPS_INFO)
        inGetTemper.nChannel = 1

        outGetTemper = NET_OUT_GET_HEATMAPS_INFO()
        outGetTemper.dwSize = sizeof(NET_OUT_GET_HEATMAPS_INFO)
        result = self.sdk.GetHeatMapsDirectly(self.loginID, inGetTemper, outGetTemper, 5000)
        if result:
            print("获取测温区域的参数值（RadiometryGetRandomRegionTemper succeed).")
            return True
        else:
            print("获取测温区域的参数值（RadiometryGetRandomRegionTemper failed)." + str(self.sdk.GetLastError()))
            return False

if __name__ == '__main__':
    my_demo = ConsoleDemo()
    my_demo.log_open()
    my_demo.get_login_info()
    result = my_demo.login()
    if not result:
        my_demo.quit_demo()
    else:
        while True:
            print("测试类型:0:区域测温; 1:点测温; 2:灰度图; 3:测温规则配置; 4:获取测温区域的参数值(test type:Regional temperature-0;Point temperature-1;Radiometry-2;Temperature rule configuration-3)")
            type = int(input("请输入测试类型(Please enter the test type):"))
            result = False
            if type == 0 or type == 1:
                result = my_demo.query_dev_info(type)
            elif type == 2:
                result = my_demo.Radiometry_Attach()
            elif type == 3:
                result = my_demo.RuleConfig()
            elif type == 4:
                result = my_demo.GetRandomRegionTemper()
            if not result:
                print("操作失败(operation failed)")
            time.sleep(10)
            my_demo.logout()
            my_demo.quit_demo()
            break
    # os._exit(0)

