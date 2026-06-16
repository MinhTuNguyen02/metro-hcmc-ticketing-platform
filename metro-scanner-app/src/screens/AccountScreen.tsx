import React, { useState, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Image,
  TouchableOpacity,
  ScrollView,
  Alert,
  ActivityIndicator,
  RefreshControl,
  TextInput,
  Modal,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { Ionicons } from '@expo/vector-icons';
import * as SecureStore from 'expo-secure-store';
import { useFocusEffect } from '@react-navigation/native'; 
import axiosClient from '../api/axiosClient';

const AccountScreen = ({ navigation }: any) => {
  const [user, setUser] = useState<any>(null);
  const [loading, setLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  // Thêm trạng thái mới để kiểm tra việc mở/đóng modal đổi mật khẩu
  const [isModalVisible, setIsModalVisible] = useState(false);
  const [oldPassword, setOldPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  //show password
  const [showOldPassword, setShowOldPassword] = useState(false);
  const [showNewPassword, setShowNewPassword] = useState(false);
  const [showConfirmPassword, setShowConfirmPassword] = useState(false);
  // Mở modal đổi mật khẩu
  const openPasswordModal = () => {
    setIsModalVisible(true);
  };

  // Đóng modal
  const closePasswordModal = () => {
    setIsModalVisible(false);
    setOldPassword('');
    setNewPassword('');
    setConfirmPassword('');
  };

  const handleChangePassword = async () => {
    if (!oldPassword || !newPassword || !confirmPassword) {
      Alert.alert('Lỗi', 'Vui lòng điền đủ các trường');
      return;
    }

    if (newPassword !== confirmPassword) {
      Alert.alert('Lỗi', 'Mật khẩu mới không khớp với xác nhận mật khẩu');
      return;
    }

    setLoading(true);

    try {
      const token = await SecureStore.getItemAsync('auth_token');
      if (!token) {
        Alert.alert('Lỗi', 'Token không tồn tại');
        return;
      }

      const response: any = await axiosClient.post('auth/reset-password', {
        token,
        old_password: oldPassword,
        new_password: newPassword,
      });

      if (response.success) {
        Alert.alert(
          'Thành công',
          'Mật khẩu đã được thay đổi. Bạn sẽ được đăng xuất để đăng nhập lại.',
          [
            {
              text: 'Đồng ý',
              onPress: async () => {
                await SecureStore.deleteItemAsync('auth_token');
                await SecureStore.deleteItemAsync('user_info');
                navigation.replace('Login'); // chuyển về màn hình Login
              },
            },
          ]
        );
      } else {
        Alert.alert('Lỗi', response.message || 'Có lỗi xảy ra khi thay đổi mật khẩu');
      }
    } catch (error: any) {
      console.log('Lỗi đổi mật khẩu:', error);
      Alert.alert('Lỗi', error?.response?.data?.message || 'Có lỗi xảy ra khi thay đổi mật khẩu');
    } finally {
      setLoading(false);
      closePasswordModal(); // đóng modal sau khi xử lý xong
    }
  };


  // Hàm lấy thông tin user mới nhất từ Server
  const fetchProfile = async () => {
    try {
      const res: any = await axiosClient.get('/auth/me');
      if (res.success && res.user) {
        setUser(res.user);
        await SecureStore.setItemAsync('user_info', JSON.stringify(res.user));
      }
    } catch (error) {
      console.log('Lỗi lấy thông tin cá nhân:', error);
      const localUser = await SecureStore.getItemAsync('user_info');
      if (localUser) setUser(JSON.parse(localUser));
    }
  };

  // Hàm refresh với indicator
  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await fetchProfile();
    setRefreshing(false);
  }, []);

  useFocusEffect(
    useCallback(() => {
      fetchProfile();
    }, [])
  );

  const handleLogout = async () => {
    Alert.alert(
      'Đăng xuất',
      'Bạn có chắc chắn muốn đăng xuất?',
      [
        { text: 'Hủy', style: 'cancel' },
        {
          text: 'Đồng ý',
          style: 'destructive',
          onPress: async () => {
            await SecureStore.deleteItemAsync('auth_token');
            await SecureStore.deleteItemAsync('user_info');
            navigation.replace('Login');
          }
        }
      ]
    );
  };

  // Hàm render dòng menu
  const MenuRow = ({ icon, title, value, isRed = false, onPress }: any) => (
    <TouchableOpacity style={styles.menuRow} onPress={onPress} disabled={!onPress}>
      <View style={[styles.iconBox, { backgroundColor: isRed ? '#FFF0F0' : '#F0F8FF' }]}>
        <Ionicons name={icon} size={20} color={isRed ? '#FF4D4F' : '#0056b3'} />
      </View>
      <View style={{ flex: 1 }}>
        <Text style={[styles.menuText, isRed && { color: '#FF4D4F' }]}>{title}</Text>
        {value && <Text style={styles.menuSubText}>{value}</Text>}
      </View>
      {!isRed && <Ionicons name="chevron-forward" size={20} color="#ccc" />}
    </TouchableOpacity>
  );

  // Ảnh mặc định nếu user chưa có avatar
  const defaultAvatar = 'https://cdn-icons-png.flaticon.com/512/149/149071.png';

  return (
    <View style={{ flex: 1, backgroundColor: '#F5F7FA' }}>
      {/* HEADER GRADIENT */}
      <LinearGradient colors={['#0056b3', '#008DDA']} style={styles.header}>
        <View style={styles.headerTopRow}>
          <Text style={styles.headerTitle}>Tài khoản</Text>
        </View>

        <View style={styles.profileBox}>
          <View style={styles.avatarContainer}>
            <Image
              source={{ uri: user?.avatar_url || defaultAvatar }}
              style={styles.avatar}
            />
            <View style={styles.editIcon}>
              <Ionicons name="camera" size={14} color="#0056b3" />
            </View>
          </View>

          <View style={{ flexDirection: 'row', alignItems: 'center' }}>
            <Text style={styles.name}>
              {user?.display_name || 'Đang tải...'}
            </Text>
          </View>

          {user?.role && (
            <View style={styles.badge}>
              <Ionicons name="shield-checkmark" size={12} color="white" />
              <Text style={styles.badgeText}>
                {user.role === 'CUSTOMER' ? 'Khách hàng thân thiết' : user.role}
              </Text>
            </View>
          )}
        </View>
      </LinearGradient>

      {/* MENU CONTAINER */}
      <ScrollView
        style={styles.menuContainer}
        contentContainerStyle={{ paddingBottom: 40 }}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
      >
        {loading && !refreshing ? (
          <ActivityIndicator size="large" color="#0056b3" style={styles.loadingIndicator} />
        ) : (
          <>
            <Text style={styles.sectionTitle}>Thông tin tài khoản</Text>
            <MenuRow
              icon="person-outline"
              title="Họ và tên"
              value={user?.display_name}
            />
            <MenuRow
              icon="mail-outline"
              title="Email"
              value={user?.primary_email}
            />
            <MenuRow
              icon="calendar-outline"
              title="Ngày tham gia"
              value={
                user?.created_at
                  ? new Date(user.created_at).toLocaleDateString('vi-VN')
                  : '---'
              }
            />


            <Text style={styles.sectionTitle}>Cài đặt & Bảo mật</Text>
            <MenuRow
              icon="lock-closed-outline"
              title="Đổi mật khẩu"
              onPress={openPasswordModal} 
            />

            <View style={{ height: 1, backgroundColor: '#eee', marginVertical: 10 }} />

            <MenuRow
              icon="log-out-outline"
              title="Đăng xuất"
              isRed
              onPress={handleLogout}
            />

            <Text style={styles.versionText}>Phiên bản 1.0.0 - Metro Connect</Text>
          </>
        )}
      </ScrollView>
      {/* Modal đổi mật khẩu */}
      <Modal
        visible={isModalVisible}
        animationType="slide"
        transparent={true}
        onRequestClose={closePasswordModal}
      >
        <View style={styles.modalContainer}>
          <View style={styles.modalContent}>
            <View style={styles.modalHeader}>
              <Text style={styles.modalTitle}>Đổi mật khẩu</Text>
              <TouchableOpacity onPress={closePasswordModal}>
                <Ionicons name="close" size={24} color="#666" />
              </TouchableOpacity>
            </View>

            {/* Mật khẩu cũ */}
            <View style={styles.inputGroup}>
              <Text style={styles.inputLabel}>Mật khẩu cũ *</Text>
              <View style={styles.inputWithIcon}>
                <TextInput
                  value={oldPassword}
                  onChangeText={setOldPassword}
                  placeholder="Nhập mật khẩu cũ"
                  secureTextEntry={!showOldPassword}
                />
                <TouchableOpacity
                  style={styles.eyeIcon}
                  onPress={() => setShowOldPassword(!showOldPassword)}
                >
                  <Ionicons
                    name={showOldPassword ? 'eye-off-outline' : 'eye-outline'}
                    size={20}
                    color="#666"
                  />
                </TouchableOpacity>
              </View>
            </View>

            {/* Mật khẩu mới */}
            <View style={styles.inputGroup}>
              <Text style={styles.inputLabel}>Mật khẩu mới *</Text>
              <View style={styles.inputWithIcon}>
                <TextInput
                  value={newPassword}
                  onChangeText={setNewPassword}
                  placeholder="Nhập mật khẩu mới"
                  secureTextEntry={!showNewPassword}
                />
                <TouchableOpacity
                  style={styles.eyeIcon}
                  onPress={() => setShowNewPassword(!showNewPassword)}
                >
                  <Ionicons
                    name={showNewPassword ? 'eye-off-outline' : 'eye-outline'}
                    size={20}
                    color="#666"
                  />
                </TouchableOpacity>
              </View>
            </View>

            {/* Xác nhận mật khẩu */}
            <View style={styles.inputGroup}>
              <Text style={styles.inputLabel}>Xác nhận mật khẩu *</Text>
              <View style={styles.inputWithIcon}>
                <TextInput
                  value={confirmPassword}
                  onChangeText={setConfirmPassword}
                  placeholder="Xác nhận mật khẩu mới"
                  secureTextEntry={!showConfirmPassword}
                />
                <TouchableOpacity
                  style={styles.eyeIcon}
                  onPress={() => setShowConfirmPassword(!showConfirmPassword)}
                >
                  <Ionicons
                    name={showConfirmPassword ? 'eye-off-outline' : 'eye-outline'}
                    size={20}
                    color="#666"
                  />
                </TouchableOpacity>
              </View>
            </View>

            {/* Actions */}
            <View style={styles.modalActions}>
              <TouchableOpacity
                style={[styles.modalButton, styles.cancelButton]}
                onPress={closePasswordModal}
              >
                <Text style={styles.cancelButtonText}>Hủy</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[styles.modalButton, styles.saveButton]}
                onPress={handleChangePassword}
                disabled={loading}
              >
                {loading ? (
                  <ActivityIndicator color="#fff" size="small" />
                ) : (
                  <Text style={styles.saveButtonText}>Lưu thay đổi</Text>
                )}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </View>

  );
};

const styles = StyleSheet.create({
  header: {
    height: 280,
    paddingTop: 60,
    alignItems: 'center',
    borderBottomLeftRadius: 30,
    borderBottomRightRadius: 30,
  },
  headerTopRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    width: '90%',
    marginBottom: 20,
  },
  headerTitle: {
    color: 'white',
    fontSize: 18,
    fontWeight: 'bold',
  },
  
  profileBox: {
    alignItems: 'center',
  },
  avatarContainer: {
    position: 'relative',
    marginBottom: 10,
  },
  avatar: {
    width: 90,
    height: 90,
    borderRadius: 45,
    borderWidth: 3,
    borderColor: 'rgba(255,255,255,0.8)',
    backgroundColor: '#fff',
  },
  editIcon: {
    position: 'absolute',
    bottom: 0,
    right: 0,
    backgroundColor: 'white',
    padding: 6,
    borderRadius: 15,
    elevation: 2,
  },
  name: {
    color: 'white',
    fontSize: 20,
    fontWeight: 'bold',
    marginBottom: 5,
  },
  badge: {
    flexDirection: 'row',
    backgroundColor: 'rgba(255,255,255,0.2)',
    paddingHorizontal: 12,
    paddingVertical: 4,
    borderRadius: 15,
    alignItems: 'center',
    marginTop: 5,
  },
  badgeText: {
    color: 'white',
    fontSize: 12,
    marginLeft: 5,
    fontWeight: '600',
  },
  menuContainer: {
    flex: 1,
    backgroundColor: 'white',
    marginHorizontal: 20,
    marginTop: -40,
    borderRadius: 20,
    padding: 20,
    shadowColor: '#000',
    shadowOpacity: 0.05,
    elevation: 5,
    marginBottom: 20,
  },
  sectionTitle: {
    fontSize: 14,
    fontWeight: 'bold',
    color: '#999',
    marginBottom: 10,
    marginTop: 10,
    textTransform: 'uppercase',
  },
  menuRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#f5f5f5',
  },
  iconBox: {
    width: 40,
    height: 40,
    borderRadius: 12,
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 15,
  },
  menuText: {
    fontSize: 15,
    fontWeight: '600',
    color: '#333',
  },
  menuSubText: {
    fontSize: 13,
    color: '#666',
    marginTop: 2,
  },
  versionText: {
    textAlign: 'center',
    color: '#ccc',
    fontSize: 12,
    marginTop: 30,
  },
  loadingIndicator: {
    marginTop: 40,
  },
  modalContainer: {
    flex: 1,
    justifyContent: 'flex-end',
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
  },
  modalContent: {
    backgroundColor: 'white',
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    maxHeight: '85%',

  },
  modalHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#f0f0f0',
  },
  modalTitle: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#333',
  },
  inputGroup: {
    marginBottom: 16,
  },
  inputLabel: {
    fontSize: 14,
    fontWeight: '600',
    color: '#555',
    marginBottom: 6,
  },
  modalActions: {
    flexDirection: 'row',
    padding: 20,
    borderTopWidth: 1,
    borderTopColor: '#f0f0f0',
  },
  modalButton: {
    flex: 1,
    paddingVertical: 12,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  cancelButton: {
    backgroundColor: '#f5f5f5',
    marginRight: 10,
  },
  saveButton: {
    backgroundColor: '#0056b3',
    marginLeft: 10,
  },
  cancelButtonText: {
    fontSize: 15,
    fontWeight: '600',
    color: '#666',
  },
  saveButtonText: {
    fontSize: 15,
    fontWeight: '600',
    color: 'white',
  },
  inputWithIcon: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 8,
    paddingHorizontal: 12,
    backgroundColor: '#fafafa',
    position: 'relative', // để icon có thể position absolute
  },
  eyeIcon: {
    position: 'absolute',
    right: 12,
  }
});

export default AccountScreen;