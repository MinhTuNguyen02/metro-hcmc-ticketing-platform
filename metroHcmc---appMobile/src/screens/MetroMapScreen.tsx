import React, { useEffect, useState, useRef, useMemo } from "react";
import {
  View,
  Text,
  StyleSheet,
  ActivityIndicator,
  TouchableOpacity,
  Alert,
  StatusBar,
  Platform,
  Modal,
  FlatList,
  Linking,
} from "react-native";
import MapView, { Marker, Polyline, PROVIDER_DEFAULT } from "react-native-maps";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons, MaterialCommunityIcons } from "@expo/vector-icons";
import { useNavigation } from "@react-navigation/native";
import * as Location from "expo-location";
import axiosClient from "../api/axiosClient";

const MetroMapScreen = () => {
  const navigation = useNavigation<any>();
  const mapRef = useRef<MapView>(null);

  // const highlightPolylineRef = useRef<Polyline | null>(null);
  // const highlightPolylineRef = useRef<Polyline | null>(null);
  const highlightPolylineRef = useRef<any>(null);
  // const highlightPolylineRef = useRef<typeof Polyline>(null);

  const [stations, setStations] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  // State cho vị trí
  const [userLocation, setUserLocation] =
    useState<Location.LocationObjectCoords | null>(null);
  const [nearestStation, setNearestStation] = useState<any>(null);

  // State Chọn vé (From -> To)
  const [fromStation, setFromStation] = useState<any>(null);
  const [toStation, setToStation] = useState<any>(null);
  const [selectingType, setSelectingType] = useState<"FROM" | "TO" | null>(
    null
  ); // Để mở Modal chọn ga
  const [tracksViewChanges, setTracksViewChanges] = useState(true);

  // Cho phép render nhãn & chấm hoàn tất trên layout engine rồi khóa lại để tối ưu mượt mà khi zoom
  useEffect(() => {
    setTracksViewChanges(true);
    const timer = setTimeout(() => {
      setTracksViewChanges(false);
    }, 1500);
    return () => clearTimeout(timer);
  }, [stations, fromStation?.code, toStation?.code, nearestStation?.code]);

  const INITIAL_REGION = {
    latitude: 10.7769,
    longitude: 106.7009,
    latitudeDelta: 0.08,
    longitudeDelta: 0.08,
  };

  // 1. Lấy dữ liệu Ga
  useEffect(() => {
    const fetchStations = async () => {
      try {
        setLoading(true);
        const res: any = await axiosClient.get("/tickets/lines/L1/stations");
        if (res.data?.stations) {
          setStations(res.data.stations);
        }
      } catch (error) {
        console.error("Lỗi tải bản đồ:", error);
      } finally {
        setLoading(false);
      }
    };
    fetchStations();
  }, []);

  // 2. Xin quyền & Lấy vị trí người dùng
  useEffect(() => {
    const startLocationTracking = async () => {
      let { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== "granted") {
        Alert.alert(
          "Thông báo",
          "Cần cấp quyền vị trí để tìm ga gần bạn nhất."
        );
        return;
      }

      // 1. Lấy vị trí hiện tại
      try {
        let location = await Location.getCurrentPositionAsync({});
        setUserLocation(location.coords);
      } catch (error) {
        console.error("Không thể lấy vị trí ban đầu:", error);
      }

      // 2. Theo dõi sự thay đổi vị trí (Tracking)
      const locationListener = await Location.watchPositionAsync(
        {
          accuracy: Location.Accuracy.BestForNavigation,
          timeInterval: 5000,
          distanceInterval: 10,
        },
        (newLoc) => {
          setUserLocation(newLoc.coords);
        }
      );

      return () => {
        locationListener.remove();
      };
    };

    startLocationTracking();
  }, []);

  // 3. Tính toán Ga gần nhất mỗi khi vị trí hoặc danh sách ga thay đổi
  useEffect(() => {
    if (!userLocation || stations.length === 0) return;

    let minDistance = Infinity;
    let nearest = null;

    stations.forEach((st) => {
      if (st.lat && st.lon) {
        const dist = getDistanceFromLatLonInKm(
          userLocation.latitude,
          userLocation.longitude,
          st.lat,
          st.lon
        );
        if (dist < minDistance) {
          minDistance = dist;
          nearest = { ...st, distance: dist };
        }
      }
    });

    setNearestStation(nearest);
    if (!fromStation && nearest) {
      setFromStation(nearest);
    }
  }, [userLocation, stations]);

  // Hàm tính khoảng cách (Haversine Formula)
  const getDistanceFromLatLonInKm = (
    lat1: number,
    lon1: number,
    lat2: number,
    lon2: number
  ) => {
    const R = 6371; // Bán kính trái đất (km)
    const dLat = deg2rad(lat2 - lat1);
    const dLon = deg2rad(lon2 - lon1);
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(deg2rad(lat1)) *
        Math.cos(deg2rad(lat2)) *
        Math.sin(dLon / 2) *
        Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  };

  const deg2rad = (deg: number) => deg * (Math.PI / 180);

  // --- ACTIONS ---
  const goToMyLocation = () => {
    if (userLocation && mapRef.current) {
      mapRef.current.animateToRegion(
        {
          latitude: userLocation.latitude,
          longitude: userLocation.longitude,
          latitudeDelta: 0.01,
          longitudeDelta: 0.01,
        },
        1000
      );
    } else {
      Alert.alert("Đang định vị...", "Vui lòng đợi trong giây lát.");
    }
  };

  const goToNearestStation = () => {
    if (nearestStation && mapRef.current) {
      mapRef.current.animateToRegion(
        {
          latitude: nearestStation.lat,
          longitude: nearestStation.lon,
          latitudeDelta: 0.005,
          longitudeDelta: 0.005,
        },
        1000
      );
    }
  };

  const routeCoordinates = useMemo(
    () =>
      [...stations]
        .filter((s) => s.lat && s.lon)
        .sort((a, b) => (Number(a.order_index) || 0) - (Number(b.order_index) || 0))
        .map((s) => ({ latitude: Number(s.lat), longitude: Number(s.lon) })),
    [stations]
  );

  // Tự động căn chỉnh Camera bao trọn toàn bộ tuyến Metro khi tải xong ga
  useEffect(() => {
    if (stations.length > 0 && mapRef.current) {
      const coords = stations
        .filter((s) => s.lat && s.lon)
        .map((s) => ({ latitude: Number(s.lat), longitude: Number(s.lon) }));
      if (coords.length > 1) {
        setTimeout(() => {
          mapRef.current?.fitToCoordinates(coords, {
            edgePadding: { top: 180, right: 50, bottom: 150, left: 50 },
            animated: true,
          });
        }, 500);
      }
    }
  }, [stations]);

  // Đảo ngược ga đi/đến
  const handleSwapStations = () => {
    const newFrom = toStation;
    const newTo = fromStation;
    setFromStation(newFrom);
    setToStation(newTo);

    // Cập nhật Polyline Highlight ngay lập tức
    setTimeout(() => {
      updateHighlightPolyline(newFrom, newTo);
    }, 0);
  };

  // Chọn ga từ Modal
  const handleSelectStation = (station: any) => {
    let newFrom = fromStation;
    let newTo = toStation;

    if (selectingType === "FROM") {
      if (toStation?.code === station.code) setToStation(null);
      setFromStation(station);
      newFrom = station;
    } else {
      if (fromStation?.code === station.code) setFromStation(null);
      setToStation(station);
      newTo = station;
    }
    setSelectingType(null);

    // Cập nhật Polyline Highlight ngay lập tức
    setTimeout(() => {
      updateHighlightPolyline(newFrom, newTo);
    }, 0);
  };

  // chọn ga từ Marker
  const handleMarkerSelect = (station: any) => {
    let newFrom = fromStation;
    let newTo = toStation;

    if (!fromStation) {
      newFrom = station;
      setFromStation(station);
    } else if (!toStation && station.code !== fromStation.code) {
      newTo = station;
      setToStation(station);
    } else if (fromStation && toStation) {
      // Nếu đã chọn đủ 2 ga, xóa cả 2 và chọn ga mới làm ga đi
      setFromStation(station);
      setToStation(null);
      newFrom = station;
      newTo = null;
    }

    // Gọi hàm cập nhật Polyline ngay sau khi state được set
    // Sử dụng setTimeout(0) để đảm bảo state được xử lý trước khi setNativeProps
    setTimeout(() => {
      updateHighlightPolyline(newFrom, newTo);
    }, 0);
  };

  const handleClearFromStation = () => {
    setFromStation(null);
    setTimeout(() => updateHighlightPolyline(null, toStation), 0);
  };

  const handleClearToStation = () => {
    setToStation(null);
    setTimeout(() => updateHighlightPolyline(fromStation, null), 0);
  };

  // --- CHỨC NĂNG MỚI: CHỈ ĐƯỜNG ---
  const handleGetDirections = async () => {
    if (!nearestStation || !nearestStation.lat || !nearestStation.lon) {
      Alert.alert("Thông báo", "Chưa xác định được ga gần nhất.");
      return;
    }

    const latitude = nearestStation.lat;
    const longitude = nearestStation.lon;

    // URL Web Google Maps (Fallback an toàn nhất)
    const browserUrl = `https://www.google.com/maps/dir/?api=1&destination=${latitude},${longitude}&travelmode=driving`;

    try {
      if (Platform.OS === "ios") {
        // iOS: Ưu tiên Google Maps App
        const googleMapsUrl = `comgooglemaps://?daddr=${latitude},${longitude}&directionsmode=driving`;
        const appleMapsUrl = `maps:?daddr=${latitude},${longitude}&dirflg=l`;

        const canOpenGoogleMaps = await Linking.canOpenURL("comgooglemaps://");
        if (canOpenGoogleMaps) {
          await Linking.openURL(googleMapsUrl);
        } else {
          // Nếu không có Google Maps, dùng Apple Maps
          await Linking.openURL(appleMapsUrl);
        }
      } else {
        // Android: Ưu tiên Google Maps App (Intent)
        const androidUrl = `google.navigation:q=${latitude},${longitude}&mode=l`;
        await Linking.openURL(androidUrl);
      }
    } catch (err) {
      console.error("Không mở được ứng dụng bản đồ, chuyển sang web:", err);
      Linking.openURL(browserUrl);
    }
  };

  // Tính giá vé (Giống logic SingleTicketSelectionScreen)
  const calculatePrice = () => {
    if (!fromStation || !toStation) return 0;
    const stops = Math.abs(toStation.order_index - fromStation.order_index);
    const basePrice = 8000;
    const extraPrice = Math.max(0, stops - 3) * 2000;
    return basePrice + extraPrice;
  };

  const handleBuyTicket = () => {
    const price = calculatePrice();
    navigation.navigate("OrderConfirmation", {
      ticketType: "SINGLE",
      fromStation: fromStation,
      toStation: toStation,
      price: price,
      productCode: null,
    });
  };

  // Đường đi được chọn (Highlight)
  const updateHighlightPolyline = (from: any, to: any) => {
    if (!highlightPolylineRef.current || !stations.length) return;

    if (!from || !to) {
      // Nếu thiếu ga, ẩn đường ray highlight
      highlightPolylineRef.current.setNativeProps({
        coordinates: [],
      });
      return;
    }

    const startIdx = Math.min(from.order_index, to.order_index);
    const endIdx = Math.max(from.order_index, to.order_index);

    // Tính toán tọa độ mới
    const newCoordinates = [...stations]
      .filter(
        (s) =>
          s.order_index >= startIdx && s.order_index <= endIdx && s.lat && s.lon
      )
      .sort((a, b) => (Number(a.order_index) || 0) - (Number(b.order_index) || 0))
      .map((s) => ({ latitude: Number(s.lat), longitude: Number(s.lon) }));

    // CẬP NHẬT TRỰC TIẾP POLYLINE MÀ KHÔNG GỌI RENDER
    highlightPolylineRef.current.setNativeProps({
      coordinates: newCoordinates,
    });
  };

  return (
    <View style={styles.container}>
      <StatusBar barStyle="dark-content" />

      {/* HEADER */}
      <SafeAreaView style={styles.topPanelWrapper} edges={["top"]}>
        <View style={styles.topCard}>
          {/* Header nhỏ */}
          <View style={styles.headerRow}>
            <TouchableOpacity
              onPress={() => navigation.goBack()}
              style={{ padding: 5 }}
            >
              <Ionicons name="arrow-back" size={24} color="#00235B" />
            </TouchableOpacity>
            <Text style={styles.headerTitle}>Bản đồ Tuyến Metro số 1</Text>
            <View style={{ width: 24 }} />
          </View>

          {/* Input Chọn Ga */}
          <View style={styles.inputContainer}>
            <View style={{ flex: 1 }}>
              <TouchableOpacity
                style={styles.inputBox}
                onPress={() => setSelectingType("FROM")}
              >
                <View style={styles.inputContent}>
                  <View style={[styles.dot, { backgroundColor: "#4CAF50" }]} />
                  <Text style={styles.inputText} numberOfLines={1}>
                    {fromStation ? fromStation.name : "Chọn ga đi"}
                  </Text>
                </View>
                {fromStation && (
                  <TouchableOpacity
                    style={styles.clearBtn}
                    onPress={(e) => {
                      e.stopPropagation(); // Ngăn sự kiện chạm lan ra inputBox (mở modal)
                      handleClearFromStation();
                    }}
                  >
                    <Ionicons name="close-circle" size={18} color="#999" />
                  </TouchableOpacity>
                )}
              </TouchableOpacity>

              <View style={{ height: 8 }} />
              <TouchableOpacity
                style={styles.inputBox}
                onPress={() => setSelectingType("TO")}
              >
                <View style={styles.inputContent}>
                  <View style={[styles.dot, { backgroundColor: "#FF5722" }]} />
                  <Text style={styles.inputText} numberOfLines={1}>
                    {toStation ? toStation.name : "Chọn ga đến"}
                  </Text>
                </View>
                {toStation && (
                  <TouchableOpacity
                    style={styles.clearBtn}
                    onPress={(e) => {
                      e.stopPropagation(); // Ngăn sự kiện chạm lan ra inputBox (mở modal)
                      handleClearToStation();
                    }}
                  >
                    <Ionicons name="close-circle" size={18} color="#999" />
                  </TouchableOpacity>
                )}
              </TouchableOpacity>
            </View>

            {/* Nút Đảo chiều */}
            <TouchableOpacity
              style={styles.swapBtn}
              onPress={handleSwapStations}
            >
              <MaterialCommunityIcons
                name="swap-vertical"
                size={24}
                color="#003eb3"
              />
            </TouchableOpacity>
          </View>

          {/* Nút Mua Vé (Hiện khi đủ thông tin) */}
          {fromStation && toStation && (
            <TouchableOpacity style={styles.buyBtn} onPress={handleBuyTicket}>
              <Text style={styles.buyBtnText}>
                Mua vé: {calculatePrice().toLocaleString()}đ
              </Text>
              <Ionicons name="arrow-forward" size={20} color="white" />
            </TouchableOpacity>
          )}
        </View>
      </SafeAreaView>

      {/* MAP */}
      {loading ? (
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color="#003eb3" />
          <Text style={{ marginTop: 10, color: "#666" }}>
            Đang tải dữ liệu bản đồ...
          </Text>
        </View>
      ) : (
        <MapView
          ref={mapRef}
          style={styles.map}
          provider={PROVIDER_DEFAULT}
          initialRegion={INITIAL_REGION}
          showsUserLocation={true} // Hiển thị chấm xanh vị trí người dùng
          showsMyLocationButton={false} // Tắt nút mặc định để dùng nút custom đẹp hơn
          showsCompass={false}
        >
          {/* Lớp bóng ngoài của đường ray Metro */}
          <Polyline
            coordinates={routeCoordinates}
            strokeColor="rgba(0, 62, 179, 0.2)"
            strokeWidth={10}
          />

          {/* Đường ray chính màu xanh của Metro Tuyến 1 */}
          <Polyline
            coordinates={routeCoordinates}
            strokeColor="#003eb3"
            strokeWidth={5}
          />

          {/* Đường ray được chọn (Highlight chặng đi - Màu cam đỏ) */}
          <Polyline
            ref={highlightPolylineRef}
            coordinates={[]}
            strokeColor="#FF5722"
            strokeWidth={7}
          />

          {stations.flatMap((station) => {
            if (!station.lat || !station.lon) return [];

            const isFrom = station.code === fromStation?.code;
            const isTo = station.code === toStation?.code;
            const isSelected = isFrom || isTo;
            const isNearest = station.code === nearestStation?.code;
            const isEndpoint =
              station.order_index === 1 ||
              station.order_index === stations.length;

            let dotBorderColor = "#003eb3";
            let dotBgColor = "#ffffff";
            if (isFrom) {
              dotBorderColor = "#4CAF50";
              dotBgColor = "#4CAF50";
            } else if (isTo) {
              dotBorderColor = "#FF5722";
              dotBgColor = "#FF5722";
            } else if (isNearest) {
              dotBorderColor = "#00C853";
            } else if (isEndpoint) {
              dotBorderColor = "#D32F2F";
            }

            const coordinate = {
              latitude: Number(station.lat),
              longitude: Number(station.lon),
            };

            return [
              // 1. Chấm tròn của Ga - Kích thước cố định 24x24, tâm tuyệt đối {0.5, 0.5}, khóa chặt 100% trên đường ray khi zoom
              <Marker
                key={`dot-${station.code}`}
                coordinate={coordinate}
                title={station.name}
                description={`Ga số ${station.order_index} (${station.code})`}
                onPress={() => handleMarkerSelect(station)}
                anchor={{ x: 0.5, y: 0.5 }}
                tracksViewChanges={tracksViewChanges}
                zIndex={isSelected || isNearest ? 10 : 8}
              >
                <View style={styles.markerDotWrapper}>
                  <View
                    style={[
                      styles.markerDot,
                      { borderColor: dotBorderColor, backgroundColor: dotBgColor },
                      isSelected && styles.selectedDot,
                      isNearest && styles.nearestDot,
                      isEndpoint && !isSelected && styles.endPoint,
                    ]}
                  >
                    {isSelected && <View style={styles.selectedInnerWhite} />}
                  </View>
                </View>
              </Marker>,

              // 2. Nhãn hiển thị đầy đủ tên Ga - Neo đỉnh tâm {0.5, 0.0}, luôn nằm ngay ngắn bên dưới chấm tròn không bao giờ lệch
              <Marker
                key={`label-${station.code}`}
                coordinate={coordinate}
                onPress={() => handleMarkerSelect(station)}
                anchor={{ x: 0.5, y: 0.0 }}
                tracksViewChanges={tracksViewChanges}
                zIndex={isSelected || isNearest ? 9 : 7}
              >
                <View style={styles.markerLabelContainer}>
                  <View
                    style={[
                      styles.markerLabel,
                      isNearest && styles.nearestLabel,
                      isFrom && { backgroundColor: "#4CAF50", borderColor: "#2E7D32" },
                      isTo && { backgroundColor: "#FF5722", borderColor: "#D84315" },
                    ]}
                  >
                    <Text
                      style={[
                        styles.markerText,
                        (isNearest || isSelected) && {
                          color: "white",
                          fontWeight: "bold",
                        },
                      ]}
                    >
                      {station.name}
                    </Text>
                  </View>
                </View>
              </Marker>,
            ];
          })}
        </MapView>
      )}

      {/* --- CÁC NÚT ĐIỀU KHIỂN (Góc phải) --- */}
      <View style={styles.controlsContainer}>
        {/* Nút tìm ga gần nhất */}
        {nearestStation && (
          <TouchableOpacity
            style={styles.nearestBtn}
            onPress={goToNearestStation}
          >
            <View>
              <Text style={styles.nearestTitle}>Ga gần nhất</Text>
              <Text style={styles.nearestName}>
                {nearestStation.name} ({nearestStation.distance?.toFixed(1)} km)
              </Text>
            </View>
            <View style={styles.nearestIcon}>
              <MaterialCommunityIcons name="train" size={20} color="white" />
            </View>
          </TouchableOpacity>
        )}
        {/* --- NÚT MỚI: CHỈ ĐƯỜNG --- */}
        <TouchableOpacity
          style={[
            styles.controlBtn,
            { marginTop: 8, backgroundColor: "#4CAF50" },
          ]}
          onPress={handleGetDirections}
        >
          <MaterialCommunityIcons
            name="directions-fork"
            size={24}
            color="white"
          />
        </TouchableOpacity>

        {/* Nút về vị trí của tôi */}
        <TouchableOpacity style={styles.controlBtn} onPress={goToMyLocation}>
          <MaterialCommunityIcons
            name="crosshairs-gps"
            size={24}
            color="#003eb3"
          />
        </TouchableOpacity>
      </View>

      {/* FOOTER LEGEND */}
      <View style={styles.footerLegend}>
        <View
          style={{
            flexDirection: "row",
            alignItems: "center",
            marginRight: 15,
          }}
        >
          <View style={[styles.legendDot, { backgroundColor: "#003eb3" }]} />
          <Text style={styles.legendText}>Đường ray</Text>
        </View>
        <View style={{ flexDirection: "row", alignItems: "center" }}>
          <View
            style={[
              styles.legendDot,
              {
                backgroundColor: "#ff4d4f",
                borderWidth: 2,
                borderColor: "white",
              },
            ]}
          />
          <Text style={styles.legendText}>Nhà ga</Text>
        </View>
        <View
          style={{ flexDirection: "row", alignItems: "center", marginLeft: 15 }}
        >
          <View
            style={[
              styles.legendDot,
              {
                backgroundColor: "#4CAF50",
                borderWidth: 2,
                borderColor: "white",
              },
            ]}
          />
          <Text style={styles.legendText}>Gần bạn</Text>
        </View>
      </View>

      {/* --- MODAL CHỌN GA (Danh sách) --- */}
      <Modal visible={selectingType !== null} animationType="slide" transparent>
        <View style={styles.modalContainer}>
          <View style={styles.modalContent}>
            <View style={styles.modalHeader}>
              <Text style={styles.modalTitle}>
                {selectingType === "FROM" ? "Chọn ga đi" : "Chọn ga đến"}
              </Text>
              <TouchableOpacity onPress={() => setSelectingType(null)}>
                <Ionicons name="close" size={24} color="#333" />
              </TouchableOpacity>
            </View>
            <FlatList
              data={stations}
              keyExtractor={(item) => item.code}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={styles.stationItem}
                  onPress={() => handleSelectStation(item)}
                >
                  <MaterialCommunityIcons
                    name="train"
                    size={24}
                    color="#003eb3"
                    style={{ marginRight: 10 }}
                  />
                  <View>
                    <Text style={styles.stationName}>{item.name}</Text>
                    {nearestStation?.code === item.code && (
                      <Text style={{ fontSize: 10, color: "#4CAF50" }}>
                        📍 Gần bạn nhất
                      </Text>
                    )}
                  </View>
                </TouchableOpacity>
              )}
            />
          </View>
        </View>
      </Modal>
    </View>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff" },
  map: { width: "100%", height: "100%" },
  loadingContainer: { flex: 1, justifyContent: "center", alignItems: "center" },

  // Top Panel
  topPanelWrapper: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    zIndex: 10,
    padding: 16,
  },
  topCard: {
    backgroundColor: "white",
    borderRadius: 16,
    padding: 15,
    shadowColor: "#000",
    shadowOpacity: 0.1,
    elevation: 5,
  },
  headerRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 15,
  },
  headerTitle: { fontSize: 16, fontWeight: "bold", color: "#00235B" },

  inputContainer: { flexDirection: "row", alignItems: "center" },
  inputBox: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "#F5F7FA",
    justifyContent: "space-between",
    padding: 10,
    borderRadius: 8,
    flex: 1,
  },
  inputContent: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    paddingRight: 5,
  },
  dot: { width: 10, height: 10, borderRadius: 5, marginRight: 8 },
  inputText: { fontSize: 14, color: "#333", fontWeight: "500" },
  swapBtn: { padding: 10, marginLeft: 10 },
  clearBtn: {
    paddingLeft: 10,
    paddingVertical: 2,
  },
  buyBtn: {
    flexDirection: "row",
    backgroundColor: "#003eb3",
    padding: 12,
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    marginTop: 15,
  },
  buyBtnText: { color: "white", fontWeight: "bold", marginRight: 5 },

  // Marker
  markerDotWrapper: {
    width: 24,
    height: 24,
    alignItems: "center",
    justifyContent: "center",
  },
  markerDot: {
    width: 14,
    height: 14,
    borderRadius: 7,
    backgroundColor: "#ffffff",
    borderWidth: 3,
    borderColor: "#003eb3",
    alignItems: "center",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.25,
    shadowRadius: 2,
    elevation: 3,
  },
  selectedDot: {
    width: 18,
    height: 18,
    borderRadius: 9,
    borderWidth: 3.5,
  },
  selectedInnerWhite: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: "#ffffff",
  },
  endPoint: {
    borderColor: "#D32F2F",
    width: 16,
    height: 16,
    borderRadius: 8,
    borderWidth: 3.5,
  },
  nearestDot: {
    borderColor: "#00C853",
    width: 18,
    height: 18,
    borderRadius: 9,
    borderWidth: 4,
  },
  markerLabelContainer: {
    paddingTop: 13,
    alignItems: "center",
    justifyContent: "flex-start",
  },
  markerLabel: {
    backgroundColor: "rgba(255,255,255,0.95)",
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 4,
    borderWidth: 1,
    borderColor: "#ddd",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.15,
    shadowRadius: 1.5,
    elevation: 2,
    alignItems: "center",
    justifyContent: "center",
  },
  nearestLabel: {
    backgroundColor: "#00C853",
    borderColor: "#009624",
  },
  markerText: {
    fontSize: 10,
    fontWeight: "700",
    color: "#222",
    textAlign: "center",
  },

  // Controls
  controlsContainer: {
    position: "absolute",
    right: 16,
    bottom: 100,
    alignItems: "flex-end",
  },
  controlBtn: {
    width: 50,
    height: 50,
    borderRadius: 25,
    backgroundColor: "white",
    justifyContent: "center",
    alignItems: "center",
    shadowColor: "#000",
    shadowOpacity: 0.2,
    elevation: 5,
    marginTop: 10,
  },

  nearestBtn: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "white",
    padding: 10,
    borderRadius: 12,
    shadowColor: "#000",
    shadowOpacity: 0.2,
    elevation: 5,
    marginBottom: 5,
  },
  nearestTitle: { fontSize: 10, color: "#666", fontWeight: "600" },
  nearestName: { fontSize: 12, color: "#003eb3", fontWeight: "bold" },
  nearestIcon: {
    width: 32,
    height: 32,
    borderRadius: 16,
    backgroundColor: "#4CAF50",
    justifyContent: "center",
    alignItems: "center",
    marginLeft: 10,
  },

  // Footer
  footerLegend: {
    position: "absolute",
    bottom: 30,
    alignSelf: "center",
    backgroundColor: "white",
    padding: 12,
    borderRadius: 30,
    flexDirection: "row",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOpacity: 0.1,
    elevation: 4,
  },
  legendDot: { width: 12, height: 12, borderRadius: 6, marginRight: 6 },
  legendText: { fontSize: 12, fontWeight: "600", color: "#555" },

  // Modal
  modalContainer: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.5)",
    justifyContent: "flex-end",
  },
  modalContent: {
    backgroundColor: "white",
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    height: "60%",
    padding: 20,
  },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginBottom: 15,
  },
  modalTitle: { fontSize: 18, fontWeight: "bold" },
  stationItem: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 15,
    borderBottomWidth: 1,
    borderColor: "#eee",
  },
  stationName: { fontSize: 16, color: "#333" },
});

export default MetroMapScreen;
