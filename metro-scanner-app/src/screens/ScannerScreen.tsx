import React, { useState, useEffect, useRef } from 'react';
import { 
  View, Text, StyleSheet, TouchableOpacity, Alert, Modal, FlatList, Vibration 
} from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera'; 
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons, MaterialCommunityIcons } from '@expo/vector-icons';
import { scannerApi } from '../api/scannerApi';
import axiosClient from '../api/axiosClient';

const ScannerScreen = ({ navigation }: any) => {
  const [permission, requestPermission] = useCameraPermissions();
  
  // State cấu hình máy quét
  const [direction, setDirection] = useState<'IN' | 'OUT'>('IN');
  const [currentStation, setCurrentStation] = useState<any>(null);
  const [stationList, setStationList] = useState<any[]>([]);
  
  // State xử lý quét
  const [scanned, setScanned] = useState(false);
  const [loading, setLoading] = useState(false);
  const [scanResult, setScanResult] = useState<{success: boolean, message: string} | null>(null);

  const isProcessing = useRef(false);
  
  // Modal chọn ga
  const [showStationModal, setShowStationModal] = useState(false);

  // 1. Xin quyền Camera & Lấy danh sách ga
  useEffect(() => {
    if (!permission?.granted) requestPermission();

    const fetchStations = async () => {
      try {
        const res: any = await axiosClient.get('/tickets/lines/L1/stations');
        if (res.data?.stations) {
          setStationList(res.data.stations);
          // Mặc định chọn ga đầu tiên (Bến Thành)
          if (res.data.stations.length > 0) setCurrentStation(res.data.stations[0]);
        }
      } catch (err) {
        console.error("Lỗi lấy danh sách ga:", err);
      }
    };
    fetchStations();
  }, []);

  // 2. Xử lý khi quét được mã QR
  const handleBarCodeScanned = async ({ data }: { data: string }) => {
    if (isProcessing.current) return;

    isProcessing.current = true;
    setScanned(true); // Chặn quét liên tục
    setLoading(true);

    Vibration.vibrate(); // Rung nhẹ báo hiệu đã nhận mã

    try {
      if (!currentStation) {
        Alert.alert("Lỗi", "Vui lòng chọn Ga hiện tại trước khi quét.");
        return;
      }

      console.log(`Scanning: QR=${data}, Station=${currentStation.code}, Dir=${direction}`);

      // Gọi API Backend
      const res: any = await scannerApi.scanTicket(data, currentStation.code, direction);

      // Hiển thị kết quả (Backend trả về message chi tiết)
      setScanResult({
        success: true,
        message: res.message || "Thành công!"
      });

    } catch (error: any) {
      console.log("Scan Error:", error);
      const msg = error.response?.data?.message || "Vé không hợp lệ hoặc lỗi hệ thống.";
      setScanResult({
        success: false,
        message: msg
      });
    } finally {
      setLoading(false);
      // Tự động reset sau 3 giây để quét người tiếp theo
      setTimeout(() => {
        setScanResult(null);
        setScanned(false);
        isProcessing.current = false;
      }, 3000);
    }
  };

  // Nếu chưa cấp quyền
  if (!permission) return <View />;
  if (!permission.granted) {
    return (
      <View style={styles.container}>
        <Text style={{textAlign: 'center', marginTop: 50}}>Cần quyền truy cập Camera để soát vé.</Text>
        <TouchableOpacity onPress={requestPermission} style={styles.btnGrant}>
            <Text style={{color: 'white'}}>Cấp quyền</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      
      {/* --- CAMERA VIEW (Full Screen) --- */}
      <CameraView
        style={StyleSheet.absoluteFill}
        facing="back"
        onBarcodeScanned={scanned ? undefined : handleBarCodeScanned}
        barcodeScannerSettings={{
          barcodeTypes: ["qr"],
        }}
      />

      {/* --- OVERLAY: Giao diện điều khiển (Nổi trên Camera) --- */}
      <SafeAreaView style={styles.overlay}>
        
        {/* 1. Header: Chọn Ga & Hướng */}
        <View style={styles.controlPanel}>
            <View style={styles.row}>
                {/* Chọn Ga */}
                <TouchableOpacity 
                    style={styles.stationSelector} 
                    onPress={() => setShowStationModal(true)}
                >
                    <MaterialCommunityIcons name="train" size={20} color="#003eb3" />
                    <View style={{marginLeft: 8}}>
                        <Text style={styles.label}>Ga hiện tại</Text>
                        <Text style={styles.value}>{currentStation?.name || "Chọn ga..."}</Text>
                    </View>
                    <Ionicons name="chevron-down" size={16} color="#666" style={{marginLeft: 'auto'}}/>
                </TouchableOpacity>

                {/* Toggle Chiều (IN/OUT) */}
                <TouchableOpacity 
                    style={[styles.directionToggle, direction === 'IN' ? styles.inMode : styles.outMode]}
                    onPress={() => setDirection(prev => prev === 'IN' ? 'OUT' : 'IN')}
                >
                    <Text style={styles.dirText}>{direction === 'IN' ? 'CHECK-IN' : 'CHECK-OUT'}</Text>
                    <MaterialCommunityIcons 
                        name={direction === 'IN' ? "login" : "logout"} 
                        size={24} color="white" 
                    />
                </TouchableOpacity>
            </View>
        </View>

        {/* 2. Khung ngắm (Center) */}
        <View style={styles.focusFrameContainer}>
            <View style={[styles.focusFrame, scanned && (scanResult?.success ? styles.borderSuccess : styles.borderFail)]}>
                <View style={styles.cornerTL} />
                <View style={styles.cornerTR} />
                <View style={styles.cornerBL} />
                <View style={styles.cornerBR} />
            </View>
            <Text style={styles.guideText}>Đưa mã QR vé vào khung hình</Text>
        </View>

        {/* 3. Kết quả Quét (Bottom Popup) */}
        {scanResult && (
            <View style={[styles.resultPopup, scanResult.success ? styles.bgSuccess : styles.bgFail]}>
                <Ionicons 
                    name={scanResult.success ? "checkmark-circle" : "alert-circle"} 
                    size={40} color="white" 
                />
                <Text style={styles.resultText}>{scanResult.message}</Text>
                
                <TouchableOpacity onPress={() => { setScanResult(null); setScanned(false); }}>
                    <Ionicons name="close" size={24} color="rgba(255,255,255,0.8)" />
                </TouchableOpacity>
            </View>
        )}

        {/* Nút Back về Dashboard */}
        <TouchableOpacity style={styles.closeBtn} onPress={() => navigation.goBack()}>
            <Ionicons name="close" size={28} color="white" />
        </TouchableOpacity>

      </SafeAreaView>

      {/* --- MODAL DANH SÁCH GA --- */}
      <Modal visible={showStationModal} animationType="slide" transparent>
        <View style={styles.modalContainer}>
            <View style={styles.modalContent}>
                <Text style={styles.modalTitle}>Chọn ga đang làm việc</Text>
                <FlatList
                    data={stationList}
                    keyExtractor={(item) => item.code}
                    renderItem={({item}) => (
                        <TouchableOpacity 
                            style={styles.stationItem}
                            onPress={() => { setCurrentStation(item); setShowStationModal(false); }}
                        >
                            <Text style={[styles.stationName, currentStation?.code === item.code && {color: '#003eb3', fontWeight: 'bold'}]}>
                                {item.name}
                            </Text>
                            {currentStation?.code === item.code && <Ionicons name="checkmark" size={20} color="#003eb3"/>}
                        </TouchableOpacity>
                    )}
                />
                <TouchableOpacity style={styles.modalClose} onPress={() => setShowStationModal(false)}>
                    <Text style={{color: 'red', fontWeight: 'bold'}}>Đóng</Text>
                </TouchableOpacity>
            </View>
        </View>
      </Modal>

    </View>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: 'black' },
  overlay: { flex: 1, justifyContent: 'space-between' },
  
  // Control Panel
  controlPanel: { margin: 16, marginTop: 40 },
  row: { flexDirection: 'row', gap: 10 },
  stationSelector: { 
    flex: 1, flexDirection: 'row', alignItems: 'center', backgroundColor: 'white', 
    padding: 10, borderRadius: 12, elevation: 5 
  },
  label: { fontSize: 10, color: '#666' },
  value: { fontSize: 14, fontWeight: 'bold', color: '#003eb3' },
  
  directionToggle: { 
    width: 100, borderRadius: 12, justifyContent: 'center', alignItems: 'center', elevation: 5 
  },
  inMode: { backgroundColor: '#4CAF50' }, 
  outMode: { backgroundColor: '#FF9800' }, 
  dirText: { color: 'white', fontWeight: 'bold', fontSize: 12, marginBottom: 2 },

  // Focus Frame
  focusFrameContainer: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  focusFrame: { width: 260, height: 260, borderWidth: 2, borderColor: 'rgba(255,255,255,0.5)', borderRadius: 20 },
  guideText: { color: 'white', marginTop: 20, fontSize: 16, fontWeight: '500', textShadowColor: 'black', textShadowRadius: 5 },
  borderSuccess: { borderColor: '#4CAF50', borderWidth: 4 },
  borderFail: { borderColor: '#F44336', borderWidth: 4 },
  cornerTL: {
    position: 'absolute', top: -2, left: -2, 
    width: 20, height: 20, 
    borderTopWidth: 4, borderLeftWidth: 4, borderColor: 'white',
    borderTopLeftRadius: 20
  },
  cornerTR: {
    position: 'absolute', top: -2, right: -2, 
    width: 20, height: 20, 
    borderTopWidth: 4, borderRightWidth: 4, borderColor: 'white',
    borderTopRightRadius: 20
  },
  cornerBL: {
    position: 'absolute', bottom: -2, left: -2, 
    width: 20, height: 20, 
    borderBottomWidth: 4, borderLeftWidth: 4, borderColor: 'white',
    borderBottomLeftRadius: 20
  },
  cornerBR: {
    position: 'absolute', bottom: -2, right: -2, 
    width: 20, height: 20, 
    borderBottomWidth: 4, borderRightWidth: 4, borderColor: 'white',
    borderBottomRightRadius: 20
  },

  // Result Popup
  resultPopup: { 
    position: 'absolute', bottom: 50, left: 20, right: 20,
    padding: 20, borderRadius: 16, flexDirection: 'row', alignItems: 'center', elevation: 10 
  },
  bgSuccess: { backgroundColor: '#4CAF50' },
  bgFail: { backgroundColor: '#F44336' },
  resultText: { color: 'white', fontSize: 16, fontWeight: 'bold', flex: 1, marginLeft: 15 },

  // Misc
  closeBtn: { position: 'absolute', top: 40, left: 16, padding: 5, backgroundColor: 'rgba(0,0,0,0.5)', borderRadius: 20 },
  btnGrant: { backgroundColor: '#003eb3', padding: 10, borderRadius: 8, marginTop: 20, alignSelf: 'center' },

  // Modal
  modalContainer: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  modalContent: { backgroundColor: 'white', borderTopLeftRadius: 20, borderTopRightRadius: 20, height: '50%', padding: 20 },
  modalTitle: { fontSize: 18, fontWeight: 'bold', marginBottom: 15, textAlign: 'center' },
  stationItem: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 15, borderBottomWidth: 1, borderColor: '#eee' },
  stationName: { fontSize: 16, color: '#333' },
  modalClose: { marginTop: 15, alignItems: 'center', padding: 10 }
});

export default ScannerScreen;