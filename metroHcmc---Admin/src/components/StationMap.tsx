import React, { useEffect } from 'react';
import { 
  MapContainer, TileLayer, Marker, Popup, useMap, Tooltip, Polyline, LayersControl 
} from 'react-leaflet';
import 'leaflet/dist/leaflet.css';
import L from 'leaflet';

// --- 1. FIX ICON LEAFLET ---
import icon from 'leaflet/dist/images/marker-icon.png';
import iconShadow from 'leaflet/dist/images/marker-shadow.png';

const DefaultIcon = L.icon({
    iconUrl: icon,
    shadowUrl: iconShadow,
    iconSize: [25, 41],
    iconAnchor: [12, 41],
    popupAnchor: [1, -34],
    tooltipAnchor: [16, -28]
});
L.Marker.prototype.options.icon = DefaultIcon;

// --- 2. COMPONENT FIX LỖI RESIZE KHI MỞ TRONG CARD / MODAL ---
const MapResizeFix = () => {
  const map = useMap();
  
  useEffect(() => {
    const timer = setTimeout(() => {
      map.invalidateSize(); 
    }, 300);
    return () => clearTimeout(timer);
  }, [map]);

  return null;
};

// --- 3. COMPONENT TỰ ĐỘNG CÂN CHỈNH GÓC NHÌN THEO GA ĐƯỢC CHỌN HOẶC TOÀN TUYẾN ---
const MapViewAdjuster = ({ 
  focusedStation, 
  stations 
}: { 
  focusedStation?: any; 
  stations: any[] 
}) => {
  const map = useMap();

  useEffect(() => {
    if (focusedStation && focusedStation.lat && focusedStation.lon) {
      map.flyTo([focusedStation.lat, focusedStation.lon], 15, { duration: 1.2 });
    } else {
      const validStations = stations.filter(s => s.lat && s.lon);
      if (validStations.length > 0) {
        const bounds = L.latLngBounds(
          validStations.map(s => [s.lat, s.lon] as [number, number])
        );
        map.fitBounds(bounds, { padding: [40, 40], maxZoom: 14 });
      }
    }
  }, [focusedStation, stations, map]);

  return null;
};

interface StationMapProps {
  stations: any[];
  focusedStation?: any;
}

const StationMap: React.FC<StationMapProps> = ({ stations, focusedStation }) => {
  const defaultCenter: [number, number] = [10.7721, 106.6983]; // Bến Thành mặc định
  const center: [number, number] = (focusedStation && focusedStation.lat && focusedStation.lon)
    ? [focusedStation.lat, focusedStation.lon]
    : defaultCenter;

  // Sắp xếp các ga theo order_index để vẽ đường ray nối các ga
  const sortedStations = [...stations]
    .filter(st => st.lat && st.lon)
    .sort((a, b) => (Number(a.order_index) || 0) - (Number(b.order_index) || 0));

  const polylineCoords: [number, number][] = sortedStations.map(st => [st.lat, st.lon]);

  return (
    <div style={{ height: '500px', width: '100%', borderRadius: 8, overflow: 'hidden', position: 'relative' }}>
      <MapContainer 
        center={center} 
        zoom={12} 
        style={{ height: '100%', width: '100%' }}
        scrollWheelZoom={true}
      >
        <LayersControl position="topright">
          {/* Lớp 1: OpenStreetMap (Mặc định - Hoàn toàn miễn phí, không watermark, bản đồ tiếng Việt) */}
          <LayersControl.BaseLayer checked name="Bản đồ đường phố (OpenStreetMap)">
            <TileLayer
              attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
              url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
              maxZoom={19}
            />
          </LayersControl.BaseLayer>

          {/* Lớp 2: Esri World Street Map (Hiện đại, rõ nét) */}
          <LayersControl.BaseLayer name="Bản đồ chi tiết (Esri Street)">
            <TileLayer
              attribution='Tiles &copy; Esri'
              url="https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}"
              maxZoom={19}
            />
          </LayersControl.BaseLayer>

          {/* Lớp 3: Ảnh Vệ tinh (Esri Satellite) */}
          <LayersControl.BaseLayer name="Ảnh vệ tinh (Satellite)">
            <TileLayer
              attribution='Tiles &copy; Esri &mdash; Source: Esri, i-cubed, USDA, USGS'
              url="https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
              maxZoom={19}
            />
          </LayersControl.BaseLayer>
        </LayersControl>
        
        {/* Fix lỗi resize & Tự động căn chỉnh vị trí camera */}
        <MapResizeFix />
        <MapViewAdjuster focusedStation={focusedStation} stations={stations} />

        {/* Vẽ tuyến đường Metro Tuyến 1 kết nối các nhà ga */}
        {polylineCoords.length > 1 && (
          <>
            {/* Đường viền bóng ngoài */}
            <Polyline
              positions={polylineCoords}
              pathOptions={{ color: '#003eb3', weight: 8, opacity: 0.3 }}
            />
            {/* Đường ray chính màu xanh của Metro Tuyến 1 */}
            <Polyline
              positions={polylineCoords}
              pathOptions={{ color: '#0056b3', weight: 4, opacity: 0.95 }}
            />
          </>
        )}

        {/* Điểm đánh dấu các nhà ga */}
        {sortedStations.map((st) => (
          <Marker key={st.code} position={[st.lat, st.lon]}>
            <Popup>
              <div style={{ textAlign: 'center', padding: '4px' }}>
                <b style={{ color: '#0056b3', fontSize: '14px' }}>{st.code} - {st.name}</b>
                <div style={{ color: '#666', marginTop: '4px' }}>{st.line_name || 'Tuyến số 1'}</div>
                <div style={{ fontSize: '12px', color: '#888', marginTop: '2px' }}>
                  Thứ tự: Ga số {st.order_index}
                </div>
              </div>
            </Popup>
            <Tooltip 
              direction="bottom" 
              offset={[0, 7]} 
              opacity={1} 
              permanent 
              className="station-label" 
            >
              {st.name}
            </Tooltip>
          </Marker>
        ))}
      </MapContainer>
    </div>
  );
};

export default StationMap;
