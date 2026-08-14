# coding=utf-8
import sys
from PyQt5.QtWidgets import QMainWindow,QApplication, QTableWidgetItem, QMessageBox
from PyQt5.QtCore import Qt
from PyQt5.QtGui import QPixmap
from PyQt5.QtCore import QThread,pyqtSignal

from AllowedListUI import Ui_MainWindow
from NetSDK.NetSDK import NetClient
from NetSDK.SDK_Struct import *
from NetSDK.SDK_Enum import *
from NetSDK.SDK_Callback import *
import datetime
from queue import Queue


class RecordInfo:
    def __init__(self):
        self.plate_number_str = ""
        self.vehicle_owner_str = ""
        self.start_time_str = ""
        self.end_time_str = ""
        self.auth_str = ""
        self.record_number_str = ""

    def get_alarm_info(self, info):
        self.plate_number_str = str(info.szPlateNumber.decode('gb2312'))
        self.vehicle_owner_str = str(info.szMasterOfCar.decode('gb2312'))
        self.start_time_str = '{}-{}-{} {}:{}:{}'.format(info.stBeginTime.dwYear, info.stBeginTime.dwMonth, info.stBeginTime.dwDay,
                                                        info.stBeginTime.dwHour, info.stBeginTime.dwMinute, info.stBeginTime.dwSecond)
        self.end_time_str = '{}-{}-{} {}:{}:{}'.format(info.stCancelTime.dwYear, info.stCancelTime.dwMonth, info.stCancelTime.dwDay,
                                                       info.stCancelTime.dwHour, info.stCancelTime.dwMinute, info.stCancelTime.dwSecond)
        self.auth_str = str(info.stAuthrityTypes[0].bAuthorityEnable)
        self.record_number_str = str(info.nRecordNo)

class AllowedListWnd(QMainWindow, Ui_MainWindow):
    def __init__(self, parent=None):
        super(AllowedListWnd, self).__init__(parent)
        self.setupUi(self)
        # 界面初始化
        self._init_ui()

        # NetSDK用到的相关变量和回调
        self.loginID = C_LLONG()
        self.m_DisConnectCallBack = fDisConnect(self.DisConnectCallBack)
        self.m_ReConnectCallBack = fHaveReConnect(self.ReConnectCallBack)

        # 获取NetSDK对象并初始化
        self.sdk = NetClient()
        self.sdk.InitEx(self.m_DisConnectCallBack)
        self.sdk.SetAutoReconnect(self.m_ReConnectCallBack)

    # 初始化界面
    def _init_ui(self):
        self.row = 0
        self.column = 0
        self.Login_pushButton.setEnabled(True)
        self.Logout_pushButton.setEnabled(False)
        self.Query_pushButton.setEnabled(False)
        self.Add_pushButton.setEnabled(False)
        self.Modify_pushButton.setEnabled(False)
        self.Delete_pushButton.setEnabled(False)
        self.AllDelete_pushButton.setEnabled(False)

        self.RecordNo_lineEdit.setReadOnly(True)

        self.IP_lineEdit.setText('172.24.31.3')
        self.Port_lineEdit.setText('37777')
        self.User_lineEdit.setText('admin')
        self.Pwd_lineEdit.setText('admin123')

        self.setWindowFlag(Qt.WindowMinimizeButtonHint)
        self.setWindowFlag(Qt.WindowCloseButtonHint)
        self.setFixedSize(self.width(), self.height())

        self.Login_pushButton.clicked.connect(self.login_btn_onclick)
        self.Logout_pushButton.clicked.connect(self.logout_btn_onclick)
        self.Query_pushButton.clicked.connect(self.query_btn_onclick)
        self.Add_pushButton.clicked.connect(self.add_record_btn_onclick)
        self.Modify_pushButton.clicked.connect(self.modify_record_btn_onclick)
        self.Delete_pushButton.clicked.connect(self.delete_record_btn_onclick)
        self.AllDelete_pushButton.clicked.connect(self.delete_all_record_btn_onclick)
        self.Query_tableWidget.clicked.connect(self.detail_table_onclick)

    def log_open(self):
        log_info = LOG_SET_PRINT_INFO()
        log_info.dwSize = sizeof(LOG_SET_PRINT_INFO)
        log_info.bSetFilePath = 1
        log_info.szLogFilePath = os.path.join(os.getcwd(), 'sdk_log.log').encode('gbk')
        result = self.sdk.LogOpen(log_info)

    # 登录设备
    def login_btn_onclick(self):
        self.Query_tableWidget.setHorizontalHeaderLabels(['车牌号(Plate No.)', '车主(Vehicle Owner)', '开始时间(Start Time)', '结束时间(End Time)', '开闸授权(Switch Authorize)', '记录号(Record No.)'])
        ip = self.IP_lineEdit.text()
        port = int(self.Port_lineEdit.text())
        username = self.User_lineEdit.text()
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
        if self.loginID:
            self.setWindowTitle('允许名单(AllowedList)-在线(OnLine)')
            self.Logout_pushButton.setEnabled(True)
            self.Login_pushButton.setEnabled(False)
            self.Query_pushButton.setEnabled(True)
            self.Add_pushButton.setEnabled(True)
            self.Modify_pushButton.setEnabled(True)
            self.Delete_pushButton.setEnabled(True)
            self.AllDelete_pushButton.setEnabled(True)
        else:
            QMessageBox.about(self, '提示(prompt)', error_msg)

    # 登出设备
    def logout_btn_onclick(self):
        # 登出
        result = self.sdk.Logout(self.loginID)
        self.Login_pushButton.setEnabled(True)
        self.Logout_pushButton.setEnabled(False)
        self.Query_pushButton.setEnabled(False)
        self.Add_pushButton.setEnabled(False)
        self.Modify_pushButton.setEnabled(False)
        self.Delete_pushButton.setEnabled(False)
        self.AllDelete_pushButton.setEnabled(False)
        self.clear_record_operate_detail()
        self.setWindowTitle("允许名单(AllowedList)-离线(OffLine)")
        self.loginID = C_LLONG(0)
        self.Query_tableWidget.clear()
        self.Query_tableWidget.setRowCount(0)
        self.row = 0
        self.column = 0
        self.Query_tableWidget.setHorizontalHeaderLabels(['车牌号(Plate No.)', '车主(Vehicle Owner)', '开始时间(Start Time)', '结束时间(End Time)', '开闸授权(Switch Authorize)', '记录号(Record No.)'])

    # 信息列表点击按钮
    # 鼠标点击信息列表后更新输入框
    # Update the input box after clicking the information list
    def detail_table_onclick(self):
        if self.Query_tableWidget.currentRow() >= 0:
            self.PlateNo_lineEdit.setText(self.Query_tableWidget.item(self.Query_tableWidget.currentRow(), 0).text())
            self.VehicleOwner_lineEdit.setText(self.Query_tableWidget.item(self.Query_tableWidget.currentRow(), 1).text())
            self.StartTime_lineEdit.setText(self.Query_tableWidget.item(self.Query_tableWidget.currentRow(), 2).text())
            self.EndTime_lineEdit.setText(self.Query_tableWidget.item(self.Query_tableWidget.currentRow(), 3).text())
            self.SwitchAuthorize_lineEdit.setText(self.Query_tableWidget.item(self.Query_tableWidget.currentRow(), 4).text())
            self.RecordNo_lineEdit.setText(self.Query_tableWidget.item(self.Query_tableWidget.currentRow(), 5).text())

    # 查询按钮
    # 允许名单模糊查询结果
    # Fuzzy Query Results of Allowed List
    def query_btn_onclick(self, no_prompt=False):
        self.row = 0
        self.column = 0
        self.Query_tableWidget.clear()
        self.Query_tableWidget.setRowCount(0)
        # self.Query_tableWidget.viewport().update()
        self.Query_tableWidget.setHorizontalHeaderLabels(['车牌号(Plate No.)', '车主(Vehicle Owner)', '开始时间(Start Time)', '结束时间(End Time)', '开闸授权(Switch Authorize)', '记录号(Record No.)'])
        inParam = NET_IN_FIND_RECORD_PARAM()
        inParam.dwSize = sizeof(NET_IN_FIND_RECORD_PARAM)
        inParam.emType = EM_NET_RECORD_TYPE.TRAFFICREDLIST
        in_condition = FIND_RECORD_TRAFFICREDLIST_CONDITION()
        in_condition.dwSize = sizeof(FIND_RECORD_TRAFFICREDLIST_CONDITION)
        text = str(self.Province_lineEdit.text()) + str(self.PlateNum_lineEdit.text())
        in_condition.szPlateNumberVague = text.encode('gb2312')
        inParam.pQueryCondition = cast(pointer(in_condition), c_void_p)
        outParam = NET_OUT_FIND_RECORD_PARAM()
        outParam.dwSize = sizeof(NET_OUT_FIND_RECORD_PARAM)
        # 按查询条件查询记录; by search filter search record
        result = self.sdk.FindRecord(self.loginID, inParam, outParam, 5000)
        if not result:
            print("FindRecord operate fail. " + self.sdk.GetLastErrorMessage())
            QMessageBox.about(self, '提示(prompt)', 'error:' + self.sdk.GetLastErrorMessage())
        else:
            print("FindRecord operate success! lFindeHandle:%s" % outParam.lFindeHandle)
            find_error = False
            while(True):
                count = 10
                inFindParam = NET_IN_FIND_NEXT_RECORD_PARAM()
                inFindParam.dwSize = sizeof(NET_IN_FIND_NEXT_RECORD_PARAM)
                inFindParam.lFindeHandle = outParam.lFindeHandle
                inFindParam.nFileCount = count
                outFindParam = NET_OUT_FIND_NEXT_RECORD_PARAM()
                outFindParam.dwSize = sizeof(NET_OUT_FIND_NEXT_RECORD_PARAM)
                outFindParam.nMaxRecordNum = count
                record_list = []
                for i in range(count):
                    record = NET_TRAFFIC_LIST_RECORD()
                    record.dwSize = sizeof(NET_TRAFFIC_LIST_RECORD)
                    record.nAuthrityNum = 1
                    record.stAuthrityTypes[0] = NET_AUTHORITY_TYPE()
                    record.stAuthrityTypes[0].dwSize = sizeof(NET_AUTHORITY_TYPE)
                    record_list.append(record)
                outFindParam.pRecordList = cast(
                    (NET_TRAFFIC_LIST_RECORD * outFindParam.nMaxRecordNum)(*record_list), c_void_p)
                # 查找记录; search record
                result = self.sdk.FindNextRecord(inFindParam, outFindParam, 5000)
                if result:
                    print("FindNextRecord operate number:%d" % outFindParam.nRetRecordNum)
                    out_records = cast(outFindParam.pRecordList, POINTER(NET_TRAFFIC_LIST_RECORD * outFindParam.nRetRecordNum)).contents
                    self.Query_tableWidget.setRowCount(self.row + outFindParam.nRetRecordNum)
                    for i in range(outFindParam.nRetRecordNum):
                        show_info = RecordInfo()
                        show_info.get_alarm_info(out_records[i])
                        item1 = QTableWidgetItem(show_info.plate_number_str)
                        self.Query_tableWidget.setItem(self.row, self.column, item1)
                        item2 = QTableWidgetItem(show_info.vehicle_owner_str)
                        self.Query_tableWidget.setItem(self.row, self.column + 1, item2)
                        item3 = QTableWidgetItem(show_info.start_time_str)
                        self.Query_tableWidget.setItem(self.row, self.column + 2, item3)
                        item4 = QTableWidgetItem(show_info.end_time_str)
                        self.Query_tableWidget.setItem(self.row, self.column + 3, item4)
                        item5 = QTableWidgetItem(show_info.auth_str)
                        self.Query_tableWidget.setItem(self.row, self.column + 4, item5)
                        item6 = QTableWidgetItem(show_info.record_number_str)
                        self.Query_tableWidget.setItem(self.row, self.column + 5, item6)
                        self.row += 1
                    # find close
                    if outFindParam.nRetRecordNum < count:
                        break
                else:
                    print("FindNextRecord operate fail. " + self.sdk.GetLastErrorMessage())
                    find_error = True
                    break
            self.clear_record_operate_detail()
            self.Query_tableWidget.viewport().update()
            self.sdk.FindRecordClose(outParam.lFindeHandle)
            if find_error:
                QMessageBox.about(self, '提示(prompt)', 'error:' + self.sdk.GetLastErrorMessage())
            else:
                if not no_prompt:
                    QMessageBox.about(self, '提示(prompt)', "查询成功(Query Success)")

    # 获取允许名单输入框信息
    # Get the allowed list input box information
    def get_allowed_list_info(self):
        info = {}
        info['PlateNumber'] = self.PlateNo_lineEdit.text()
        info['VehicleOwner'] = self.VehicleOwner_lineEdit.text()
        info['StartTime'] = self.StartTime_lineEdit.text()
        info['EndTime'] = self.EndTime_lineEdit.text()
        info['Auth'] = self.SwitchAuthorize_lineEdit.text()
        info['RecordNo'] = self.RecordNo_lineEdit.text()
        if info['PlateNumber'] == '' or info['VehicleOwner'] == '' or \
            info['StartTime'] == '' or info['EndTime'] == '' or info['Auth'] == '':
            return False, info
        else:
            if len(info['PlateNumber'].encode('gb2312')) > 31 or \
                len(info['VehicleOwner'].encode('gb2312')) > 15:
                return False, info
            try:
                datetime.datetime.strptime(info['StartTime'], '%Y-%m-%d %H:%M:%S')
                datetime.datetime.strptime(info['EndTime'], '%Y-%m-%d %H:%M:%S')
                int(info['Auth'])
            except:
                return False, info
            return True, info

    # 信息格式化
    # info format
    def info_format(self, info):
        record = NET_TRAFFIC_LIST_RECORD()
        record.dwSize = sizeof(NET_TRAFFIC_LIST_RECORD)
        record.szPlateNumber = info['PlateNumber'].encode('gb2312')
        record.szMasterOfCar = info['VehicleOwner'].encode('gb2312')
        date = datetime.datetime.strptime(info['StartTime'], '%Y-%m-%d %H:%M:%S')
        record.stBeginTime = NET_TIME()
        record.stBeginTime.dwYear = date.year
        record.stBeginTime.dwMonth = date.month
        record.stBeginTime.dwDay = date.day
        record.stBeginTime.dwHour = date.hour
        record.stBeginTime.dwMinute = date.minute
        record.stBeginTime.dwSecond = date.second
        date = datetime.datetime.strptime(info['EndTime'], '%Y-%m-%d %H:%M:%S')
        record.stCancelTime = NET_TIME()
        record.stCancelTime.dwYear = date.year
        record.stCancelTime.dwMonth = date.month
        record.stCancelTime.dwDay = date.day
        record.stCancelTime.dwHour = date.hour
        record.stCancelTime.dwMinute = date.minute
        record.stCancelTime.dwSecond = date.second
        record.nAuthrityNum = 1
        record.stAuthrityTypes[0] = NET_AUTHORITY_TYPE()
        record.stAuthrityTypes[0].dwSize = sizeof(NET_AUTHORITY_TYPE)
        record.stAuthrityTypes[0].emAuthorityType = EM_NET_AUTHORITY_TYPE.NET_AUTHORITY_OPEN_GATE
        record.stAuthrityTypes[0].bAuthorityEnable = int(info['Auth'])
        return record

    # 允许名单操作
    # Allowed list operate
    def operate_record(self, type):
        verify, info = self.get_allowed_list_info()
        if not verify:
            QMessageBox.about(self, '提示(prompt)', "请输入有效数据(Please Enter Valid Data)")
            return -1
        else:
            inParam = NET_IN_OPERATE_TRAFFIC_LIST_RECORD()
            inParam.dwSize = sizeof(NET_IN_OPERATE_TRAFFIC_LIST_RECORD)
            inParam.emOperateType = type
            inParam.emRecordType = EM_NET_RECORD_TYPE.TRAFFICREDLIST
            if type == EM_RECORD_OPERATE_TYPE.NET_TRAFFIC_LIST_INSERT:
                operate_info = NET_INSERT_RECORD_INFO()
                operate_info.dwSize = sizeof(NET_INSERT_RECORD_INFO)
                record = self.info_format(info)
                operate_info.pRecordInfo = cast(pointer(record), POINTER(NET_TRAFFIC_LIST_RECORD))
            elif type == EM_RECORD_OPERATE_TYPE.NET_TRAFFIC_LIST_UPDATE:
                operate_info = NET_UPDATE_RECORD_INFO()
                operate_info.dwSize = sizeof(NET_UPDATE_RECORD_INFO)
                record = self.info_format(info)
                record.nRecordNo = int(info['RecordNo'])
                operate_info.pRecordInfo = cast(pointer(record), POINTER(NET_TRAFFIC_LIST_RECORD))
            else:
                operate_info = NET_REMOVE_RECORD_INFO()
                operate_info.dwSize = sizeof(NET_REMOVE_RECORD_INFO)
                operate_info.nRecordNo = int(info['RecordNo'])
            inParam.pstOpreateInfo = cast(pointer(operate_info), c_void_p)
            outParam = NET_OUT_OPERATE_TRAFFIC_LIST_RECORD()
            outParam.dwSize = sizeof(NET_OUT_OPERATE_TRAFFIC_LIST_RECORD)
            result = self.sdk.OperateTrafficList(self.loginID, inParam, outParam, 5000)
            if not result:
                print("OperateTrafficList operate fail. " + self.sdk.GetLastErrorMessage())
                return 0
            self.query_btn_onclick(no_prompt=True)
            self.clear_record_operate_detail()
            return 1

    # 增加按钮
    # Add button
    def add_record_btn_onclick(self):
        result = self.operate_record(EM_RECORD_OPERATE_TYPE.NET_TRAFFIC_LIST_INSERT)
        if result == 1:
            QMessageBox.about(self, '提示(prompt)', "添加成功(Add Success)")
        elif result == 0:
            QMessageBox.about(self, '提示(prompt)', "添加失败(Add Failed)")

    # 修改按钮
    # Modify button
    def modify_record_btn_onclick(self):
        if self.Query_tableWidget.currentRow() < 0:
            QMessageBox.about(self, '提示(prompt)', "请选择一条记录(Please Select A Record)")
        else:
            result = self.operate_record(EM_RECORD_OPERATE_TYPE.NET_TRAFFIC_LIST_UPDATE)
            if result == 1:
                QMessageBox.about(self, '提示(prompt)', "修改成功(Modify Success)")
            elif result == 0:
                QMessageBox.about(self, '提示(prompt)', "修改失败(Modify Failed)")

    # 删除按钮
    # Delete button
    def delete_record_btn_onclick(self):
        if self.Query_tableWidget.currentRow() < 0:
            QMessageBox.about(self, '提示(prompt)', "请选择一条记录(Please Select A Record)")
        else:
            result = self.operate_record(EM_RECORD_OPERATE_TYPE.NET_TRAFFIC_LIST_REMOVE)
            if result == 1:
                QMessageBox.about(self, '提示(prompt)', "删除成功(Modify Success)")
            elif result == 0:
                QMessageBox.about(self, '提示(prompt)', "删除失败(Modify Failed)")

    # 全部删除按钮
    # Delete all button
    def delete_all_record_btn_onclick(self):
        type = CtrlType.RECORDSET_CLEAR
        inParam = NET_CTRL_RECORDSET_PARAM()
        inParam.dwSize = sizeof(NET_CTRL_RECORDSET_PARAM)
        inParam.emType = EM_NET_RECORD_TYPE.TRAFFICREDLIST
        result = self.sdk.ControlDevice(self.loginID, type, inParam, 5000)
        if result:
            QMessageBox.about(self, '提示(prompt)', "全部删除成功(All Deleted Successfully)")
        else:
            print("ControlDevice operate fail. " + self.sdk.GetLastErrorMessage())
            QMessageBox.about(self, '提示(prompt)', "全部删除失败(All Delete Failed)")
        self.row = 0
        self.column = 0
        self.clear_record_operate_detail()
        self.Query_tableWidget.clear()
        self.Query_tableWidget.setRowCount(0)
        self.Query_tableWidget.viewport().update()
        self.Query_tableWidget.setHorizontalHeaderLabels(['车牌号(Plate No.)', '车主(Vehicle Owner)', '开始时间(Start Time)', '结束时间(End Time)', '开闸授权(Switch Authorize)', '记录号(Record No.)'])

    # 清除输入框
    def clear_record_operate_detail(self):
        self.PlateNo_lineEdit.setText('')
        self.VehicleOwner_lineEdit.setText('')
        self.StartTime_lineEdit.setText('')
        self.EndTime_lineEdit.setText('')
        self.SwitchAuthorize_lineEdit.setText('')
        self.RecordNo_lineEdit.setText('')

    # 实现断线回调函数功能
    def DisConnectCallBack(self, lLoginID, pchDVRIP, nDVRPort, dwUser):
        self.setWindowTitle("允许名单(AllowedList)-离线(OffLine)")

    # 实现断线重连回调函数功能
    def ReConnectCallBack(self, lLoginID, pchDVRIP, nDVRPort, dwUser):
        self.setWindowTitle('允许名单(AllowedList)-在线(OnLine)')

    # 关闭主窗口时清理资源
    def closeEvent(self, event):
        event.accept()
        if self.loginID:
            self.sdk.Logout(self.loginID)
            self.loginID = 0
        self.sdk.Cleanup()
        self.Query_tableWidget.clear()
        self.Query_tableWidget.setRowCount(0)

if __name__ == '__main__':
    app = QApplication(sys.argv)
    my_wnd = AllowedListWnd()
    my_wnd.log_open()
    my_wnd.show()
    sys.exit(app.exec_())
