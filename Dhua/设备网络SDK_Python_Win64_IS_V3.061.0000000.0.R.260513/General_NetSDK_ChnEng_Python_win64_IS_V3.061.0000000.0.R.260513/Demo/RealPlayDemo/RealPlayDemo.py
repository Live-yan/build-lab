# coding=utf-8
import sys
from PyQt5.QtWidgets import QApplication, QMainWindow, QMessageBox, QTableWidgetItem
from PyQt5.QtCore import Qt
from ctypes import *

from RealPlayUI import Ui_MainWindow
from NetSDK.NetSDK import NetClient
from NetSDK.SDK_Callback import fDisConnect, fHaveReConnect, fDecCBFun, fRealDataCallBackEx2
from NetSDK.SDK_Enum import SDK_RealPlayType, EM_LOGIN_SPAC_CAP_TYPE, EM_REALDATA_FLAG, EM_REAL_DATA_TYPE
from NetSDK.SDK_Struct import C_LLONG, sys_platform, NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY, NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY, PLAY_FRAME_INFO,LOG_SET_PRINT_INFO, NET_IN_REALPLAY_BY_DATA_TYPE, NET_OUT_REALPLAY_BY_DATA_TYPE

from NetSDK.SDK_Struct import CB_FUNCTYPE, C_DWORD, C_LDWORD
fRealDataEx = CB_FUNCTYPE(None, C_LLONG, C_DWORD, POINTER(c_byte), C_DWORD, C_LLONG, C_LDWORD)

import os

def write_to_offset(file_path, offset, data):
    # 打开文件，使用'ab+'模式以便读写二进制数据
    #print("seek:", offset)
    with open(file_path, 'r+b') as file:
        # 移动文件指针到指定的偏移位置
        file.seek(offset)
        # 写入数据
        file.write(data)

class MyMainWindow(QMainWindow, Ui_MainWindow):
    def __init__(self, parent=None):
        super(MyMainWindow, self).__init__(parent)
        self.setupUi(self)

        # 界面初始化
        self._init_ui()

        # NetSDK用到的相关变量和回调
        self.loginID = C_LLONG()
        self.playID = C_LLONG()
        self.freePort = c_int()
        self.m_DisConnectCallBack = fDisConnect(self.DisConnectCallBack)
        self.m_ReConnectCallBack = fHaveReConnect(self.ReConnectCallBack)
        self.m_DecodingCallBack = fDecCBFun(self.DecodingCallBack)
        self.m_RealDataCallBack = fRealDataCallBackEx2(self.RealDataCallBack)
        self.m_fRealDataEx = fRealDataEx(self.RealDataEx)
        self.playType = c_int()
        self.offset = c_int()


        # 获取NetSDK对象并初始化
        self.sdk = NetClient()
        self.sdk.InitEx(self.m_DisConnectCallBack)
        self.sdk.SetAutoReconnect(self.m_ReConnectCallBack)

    # 初始化界面
    def _init_ui(self):
        self.login_btn.setText('登录(Login)')
        self.play_btn.setText('预览(Play)')
        self.play_btn.setEnabled(False)

        self.IP_lineEdit.setText('172.13.76.15')
        self.Port_lineEdit.setText('37777')
        self.Name_lineEdit.setText('admin')
        self.Pwd_lineEdit.setText('admin123')

        self.setWindowFlag(Qt.WindowMinimizeButtonHint)
        self.setWindowFlag(Qt.WindowCloseButtonHint)
        self.setFixedSize(self.width(), self.height())

        self.login_btn.clicked.connect(self.login_btn_onclick)
        self.play_btn.clicked.connect(self.play_btn_onclick)
        self.playconvert_btn.clicked.connect(self.playconvert_btn_onclick)


        self.PlayMode_comboBox.addItem('CallBack')
        if sys_platform == 'windows':
            self.PlayMode_comboBox.addItem('PlaySDK')

    def log_open(self):
        log_info = LOG_SET_PRINT_INFO()
        log_info.dwSize = sizeof(LOG_SET_PRINT_INFO)
        log_info.bSetFilePath = 1
        log_info.szLogFilePath = os.path.join(os.getcwd(), 'sdk_log.log').encode('gbk')
        result = self.sdk.LogOpen(log_info)

    def login_btn_onclick(self):
        if not self.loginID:
            ip = self.IP_lineEdit.text()
            port = int(self.Port_lineEdit.text())
            username = self.Name_lineEdit.text()
            password = self.Pwd_lineEdit.text()

            stuInParam = NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY()
            stuInParam.dwSize = sizeof(NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY)
            stuInParam.szIP = ip.encode()
            stuInParam.nPort = port
            stuInParam.szUserName = username.encode()
            stuInParam.szPassword = password.encode()
            stuInParam.emSpecCap = EM_LOGIN_SPAC_CAP_TYPE.TCP
            stuInParam.pCapParam = None

            stuOutParam = NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY()
            stuOutParam.dwSize = sizeof(NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY)

            self.loginID, device_info, error_msg = self.sdk.LoginWithHighLevelSecurity(stuInParam, stuOutParam)
            if self.loginID != 0:
                self.setWindowTitle('实时预览(RealPlay)-在线(OnLine)')
                self.login_btn.setText('登出(Logout)')
                self.play_btn.setEnabled(True)
                self.play_btn.setText("预览(Play)")
                for i in range(int(device_info.nChanNum)):
                    self.Channel_comboBox.addItem(str(i))
                self.StreamTyp_comboBox.setEnabled(True)
                self.PlayMode_comboBox.setEnabled(True)
                self.StreamConvert_comboBox.setEnabled(True)
                self.playconvert_btn.setEnabled(True)
            else:
                QMessageBox.about(self, '提示(prompt)', error_msg)
        else:
            if self.playID:
                self.sdk.StopRealPlayEx(self.playID)
                self.play_btn.setText("预览(Play)")
                self.playconvert_btn.setText("转码预览(Play)")
                self.playID = 0
                self.PlayWnd.repaint()
                if 0 == self.PlayMode_comboBox.currentIndex():
                    self.sdk.SetDecCallBack(self.freePort, None)
                    self.sdk.Stop(self.freePort)
                    self.sdk.CloseStream(self.freePort)
                    self.sdk.ReleasePort(self.freePort)

            result = self.sdk.Logout(self.loginID)
            if result:
                self.setWindowTitle("实时预览(RealPlay)-离线(OffLine)")
                self.login_btn.setText("登录(Login)")
                self.loginID = 0
                self.play_btn.setEnabled(False)
                self.StreamTyp_comboBox.setEnabled(False)
                self.PlayMode_comboBox.setEnabled(False)
                self.StreamConvert_comboBox.setEnabled(False)
                self.playconvert_btn.setEnabled(False)
                self.Channel_comboBox.clear()

    def play_btn_onclick(self):
        if not self.playID:
            self.playconvert_btn.setEnabled(False)
            if 1 == self.PlayMode_comboBox.currentIndex():
                channel = self.Channel_comboBox.currentIndex()
                if self.StreamTyp_comboBox.currentIndex() == 0:
                    stream_type = SDK_RealPlayType.Realplay
                else:
                    stream_type = SDK_RealPlayType.Realplay_1
                self.playID = self.sdk.RealPlayEx(self.loginID, channel, int(self.PlayWnd.winId()), stream_type)
                if self.playID != 0:
                    self.play_btn.setText("停止(Stop)")
                    self.StreamTyp_comboBox.setEnabled(False)
                    self.PlayMode_comboBox.setEnabled(False)
                    self.StreamConvert_comboBox.setEnabled(False)
                    self.playconvert_btn.setEnabled(False)

                else:
                    QMessageBox.about(self, '提示(prompt)', self.sdk.GetLastErrorMessage())
            else:
                result, self.freePort = self.sdk.GetFreePort()
                if not result:
                    pass
                self.sdk.OpenStream(self.freePort)
                self.sdk.Play(self.freePort, int(self.PlayWnd.winId()))

                channel = self.Channel_comboBox.currentIndex()
                if self.StreamTyp_comboBox.currentIndex() == 0:
                    stream_type = SDK_RealPlayType.Realplay
                else:
                    stream_type = SDK_RealPlayType.Realplay_1
                self.playID = self.sdk.RealPlayEx(self.loginID, channel, 0, stream_type)
                if self.playID != 0:
                    self.play_btn.setText("停止(Stop)")
                    self.StreamTyp_comboBox.setEnabled(False)
                    self.PlayMode_comboBox.setEnabled(False)
                    self.StreamConvert_comboBox.setEnabled(False)
                    self.playconvert_btn.setEnabled(False)
                    self.sdk.SetRealDataCallBackEx2(self.playID, self.m_RealDataCallBack, None, EM_REALDATA_FLAG.RAW_DATA)
                    self.sdk.SetDecCallBack(self.freePort, self.m_DecodingCallBack)
        else:
            result = self.sdk.StopRealPlayEx(self.playID)
            if result:
                self.play_btn.setText("预览(Play)")
                self.StreamTyp_comboBox.setEnabled(True)
                self.PlayMode_comboBox.setEnabled(True)
                self.StreamConvert_comboBox.setEnabled(True)
                self.playconvert_btn.setEnabled(True)
                self.playID = 0
                self.PlayWnd.repaint()
                if 0 == self.PlayMode_comboBox.currentIndex():
                    self.sdk.SetDecCallBack(self.freePort, None)
                    self.sdk.Stop(self.freePort)
                    self.sdk.CloseStream(self.freePort)
                    self.sdk.ReleasePort(self.freePort)

    # 实现断线回调函数功能
    def DisConnectCallBack(self, lLoginID, pchDVRIP, nDVRPort, dwUser):
        self.setWindowTitle("实时预览(RealPlay)-离线(OffLine)")

    # 实现断线重连回调函数功能
    def ReConnectCallBack(self, lLoginID, pchDVRIP, nDVRPort, dwUser):
        self.setWindowTitle('实时预览(RealPlay)-在线(OnLine)')

    # 拉流回调函数功能
    def RealDataCallBack(self, lRealHandle, dwDataType, pBuffer, dwBufSize, param, dwUser):
        if lRealHandle == self.playID:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./data.dav', 'ab+') as data_file:
                data_file.write(data_buffer)
            self.sdk.InputData(self.freePort, pBuffer, dwBufSize)

    # 转码拉流回调函数功能
    def RealDataEx(self, lRealHandle, dwDataType, pBuffer, dwBufSize, param, dwUser):

        if dwDataType <= 1000:
            if(self.playType == 0):
                data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
                with open('./dataType.dav', 'ab+') as data_file:
                    data_file.write(data_buffer)
            return

        #mp4 保存到offset处
        if dwDataType == 1003:
            #print(param)
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            if(param < self.offset):
                write_to_offset('./dataType.mp4', param, data_buffer)
            else:
                with open('./dataType.mp4', 'ab+') as data_file:
                    data_file.write(data_buffer)
            self.offset = param
        elif dwDataType == 1001:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.gbps', 'ab+') as data_file:
                data_file.write(data_buffer)
        elif dwDataType == 1002:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.ts', 'ab+') as data_file:
                data_file.write(data_buffer)
        elif dwDataType == 1004:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.raw', 'ab+') as data_file:
                data_file.write(data_buffer)
        elif dwDataType == 1005:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.flv', 'ab+') as data_file:
                data_file.write(data_buffer)
        elif dwDataType == 1006:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.ps', 'ab+') as data_file:
                data_file.write(data_buffer)
        elif dwDataType == 1007:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.dhts', 'ab+') as data_file:
                data_file.write(data_buffer)
        elif dwDataType == 1008:
            data_buffer = cast(pBuffer, POINTER(c_ubyte * dwBufSize)).contents
            with open('./dataType.cdjfps', 'ab+') as data_file:
                data_file.write(data_buffer)


    # PLAYSDK解码回调函数功能
    def DecodingCallBack(self, nPort, pBuf, nSize, pFrameInfo, pUserData, nReserved2):
        # here get YUV data, pBuf is YUV data IYUV/YUV420 ,size is nSize, pFrameInfo is frame info with height, width.
        data = cast(pBuf, POINTER(c_ubyte * nSize)).contents
        info = pFrameInfo.contents
        # info.nType == 3 is YUV data,others ard audio data.
        # you can parse YUV420 data to RGB
        if info.nType == 3:
            pass


    def playconvert_btn_onclick(self):

        if not self.playID:
            self.play_btn.setEnabled(False)

            channel = self.Channel_comboBox.currentIndex()

            stuInParam = NET_IN_REALPLAY_BY_DATA_TYPE()
            stuInParam.dwSize = sizeof(NET_IN_REALPLAY_BY_DATA_TYPE)
            stuInParam.nChannelID = channel
            stuInParam.hWnd = int(self.PlayWnd.winId())
            stuInParam.cbRealDataEx = self.m_fRealDataEx
            stuInParam.emDataType =self.StreamConvert_comboBox.currentIndex()
            self.playType = self.StreamConvert_comboBox.currentIndex()
            self.offset = 0
            if(self.StreamConvert_comboBox.currentIndex() == 3) :
                stuInParam.nMP4Type = 1

            stuOutParam = NET_OUT_REALPLAY_BY_DATA_TYPE()
            stuOutParam.dwSize = sizeof(NET_OUT_REALPLAY_BY_DATA_TYPE)
            self.playID = self.sdk.RealPlayByDataType(self.loginID, stuInParam, stuOutParam, 5000)
            if self.playID != 0:
                self.playconvert_btn.setText("停止(Stop)")
                self.StreamTyp_comboBox.setEnabled(False)
                self.PlayMode_comboBox.setEnabled(False)
                self.StreamConvert_comboBox.setEnabled(False)
                self.play_btn.setEnabled(False)

            else:
                QMessageBox.about(self, '提示(prompt)', self.sdk.GetLastErrorMessage())

        else:
            result = self.sdk.StopRealPlayEx(self.playID)
            if result:
                self.playconvert_btn.setText("转码预览(Play)")
                self.StreamTyp_comboBox.setEnabled(True)
                self.PlayMode_comboBox.setEnabled(True)
                self.StreamConvert_comboBox.setEnabled(True)
                self.play_btn.setEnabled(True)
                self.playID = 0
                self.PlayWnd.repaint()


    # 关闭主窗口时清理资源
    def closeEvent(self, event):
        event.accept()
        if  self.loginID:
            self.sdk.Logout(self.loginID)
        self.sdk.Cleanup()

if __name__ == '__main__':
    app = QApplication(sys.argv)
    my_wnd = MyMainWindow()
    my_wnd.log_open()
    my_wnd.show()
    sys.exit(app.exec_())
