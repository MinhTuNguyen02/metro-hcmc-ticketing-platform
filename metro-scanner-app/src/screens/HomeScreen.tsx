import React, { useEffect, useState } from 'react';
import { 
  View, Text, StyleSheet, TouchableOpacity, Alert, StatusBar, Image 
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons, MaterialCommunityIcons } from '@expo/vector-icons';
import * as SecureStore from 'expo-secure-store';

const HomeScreen = ({ navigation }: any) => {
  const [user, setUser] = useState<any>(null);

  // Lấy thông tin nhân viên đã lưu khi Login
  useEffect(() => {
    const loadUser = async () => {
      try {
        const jsonStr = await SecureStore.getItemAsync('user_info');
        if (jsonStr) {
          setUser(JSON.parse(jsonStr));
        }
      } catch (e) {
        console.error("Lỗi load user:", e);
      }
    };
    loadUser();
  }, []);

  const handleLogout = async () => {
    Alert.alert("Đăng xuất", "Bạn có chắc chắn muốn đăng xuất?", [
      { text: "Hủy", style: "cancel" },
      { 
        text: "Đồng ý", 
        style: "destructive",
        onPress: async () => {
          await SecureStore.deleteItemAsync('user_token');
          await SecureStore.deleteItemAsync('user_info');
          // Reset stack về màn hình Login
          navigation.reset({ index: 0, routes: [{ name: 'Login' }] });
        }
      }
    ]);
  };

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar barStyle="dark-content" backgroundColor="white" />

      {/* --- HEADER --- */}
      <View style={styles.header}>
        <View>
          <Text style={styles.greeting}>Xin chào,</Text>
          <Text style={styles.username}>{user?.display_name || 'Nhân viên Metro'}</Text>
          <View style={styles.roleBadge}>
            <Text style={styles.roleText}>{user?.role || 'INSPECTOR'}</Text>
          </View>
        </View>
        <TouchableOpacity onPress={handleLogout} style={styles.logoutBtn}>
          <Ionicons name="log-out-outline" size={24} color="#D32F2F" />
        </TouchableOpacity>
      </View>

      {/* --- BODY --- */}
      <View style={styles.body}>

        {/* NÚT MỞ MÁY QUÉT (Chính) */}
        <TouchableOpacity 
          style={styles.scanButton} 
          onPress={() => navigation.navigate('Scanner')}
        >
          <View style={styles.iconCircle}>
            <MaterialCommunityIcons name="qrcode-scan" size={40} color="#003eb3" />
          </View>
          <Text style={styles.scanBtnTitle}>Bắt đầu Soát vé</Text>
          <Text style={styles.scanBtnSub}>Chạm để mở camera</Text>
        </TouchableOpacity>

      </View>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#F5F7FA' },
  
  header: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start',
    padding: 20, backgroundColor: 'white', borderBottomLeftRadius: 20, borderBottomRightRadius: 20,
    elevation: 4, shadowColor: '#000', shadowOpacity: 0.05
  },
  greeting: { fontSize: 14, color: '#666' },
  username: { fontSize: 20, fontWeight: 'bold', color: '#00235B', marginBottom: 4 },
  roleBadge: { backgroundColor: '#E3F2FD', paddingHorizontal: 8, paddingVertical: 2, borderRadius: 4, alignSelf: 'flex-start' },
  roleText: { fontSize: 10, color: '#003eb3', fontWeight: 'bold' },
  logoutBtn: { padding: 10, backgroundColor: '#FFEBEE', borderRadius: 12 },

  body: { flex: 1, padding: 20, alignItems: 'center' },

  // Nút Quét Lớn
  scanButton: {
    width: 260, height: 260, borderRadius: 130, backgroundColor: '#003eb3',
    justifyContent: 'center', alignItems: 'center', elevation: 10, shadowColor: '#003eb3', shadowOpacity: 0.4, shadowRadius: 10,
    marginBottom: 40
  },
  iconCircle: {
    width: 80, height: 80, borderRadius: 40, backgroundColor: 'white',
    justifyContent: 'center', alignItems: 'center', marginBottom: 15
  },
  scanBtnTitle: { fontSize: 22, fontWeight: 'bold', color: 'white' },
  scanBtnSub: { fontSize: 14, color: 'rgba(255,255,255,0.7)', marginTop: 5 },
});

export default HomeScreen;