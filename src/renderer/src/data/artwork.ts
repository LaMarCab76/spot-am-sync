import plNoches from '../assets/covers/pl-noches.jpg'
import plFocus from '../assets/covers/pl-focus.jpg'
import plIndie from '../assets/covers/pl-indie.jpg'
import plLiked from '../assets/covers/pl-liked.jpg'
import plRock from '../assets/covers/pl-rock.jpg'
import plLofi from '../assets/covers/pl-lofi.jpg'
import plRuta from '../assets/covers/pl-ruta.jpg'
import plDomingo from '../assets/covers/pl-domingo.jpg'
import alCostaNorte from '../assets/covers/al-costa-norte.jpg'
import alPostales from '../assets/covers/al-postales.jpg'
import alAsfalto from '../assets/covers/al-asfalto.jpg'
import alVeranoEterno from '../assets/covers/al-verano-eterno.jpg'
import alRevelado from '../assets/covers/al-revelado.jpg'
import alKilometroCero from '../assets/covers/al-kilometro-cero.jpg'
import alLowTide from '../assets/covers/al-low-tide.jpg'
import alGreenhouse from '../assets/covers/al-greenhouse.jpg'
import alLumen from '../assets/covers/al-lumen.jpg'
import alWeather from '../assets/covers/al-weather.jpg'
import alFiebre from '../assets/covers/al-fiebre.jpg'
import alSemana from '../assets/covers/al-semana.jpg'
import alCiudadDormida from '../assets/covers/al-ciudad-dormida.jpg'
import alAvenida from '../assets/covers/al-avenida.jpg'
import alInterferencia from '../assets/covers/al-interferencia.jpg'
import alAltoVoltaje from '../assets/covers/al-alto-voltaje.jpg'
import alVertigo from '../assets/covers/al-vertigo.jpg'
import alApuntes from '../assets/covers/al-apuntes.jpg'
import alSiesta from '../assets/covers/al-siesta.jpg'
import alEnVivo from '../assets/covers/al-en-vivo.jpg'

// Sample artwork (Unsplash, see CREDITS.md). Real covers come from the services.
export const playlistArt = {
  noches: plNoches,
  focus: plFocus,
  indie: plIndie,
  liked: plLiked,
  rock: plRock,
  lofi: plLofi,
  ruta: plRuta,
  domingo: plDomingo
}

export const albumArt: Record<string, string> = {
  'Costa Norte': alCostaNorte,
  Postales: alPostales,
  Asfalto: alAsfalto,
  'Verano Eterno': alVeranoEterno,
  Revelado: alRevelado,
  'Kilómetro Cero': alKilometroCero,
  'Low Tide': alLowTide,
  Greenhouse: alGreenhouse,
  Lumen: alLumen,
  Weather: alWeather,
  Fiebre: alFiebre,
  Semana: alSemana,
  'Ciudad Dormida': alCiudadDormida,
  Avenida: alAvenida,
  Interferencia: alInterferencia,
  'Alto Voltaje': alAltoVoltaje,
  'Vértigo': alVertigo,
  Apuntes: alApuntes,
  Siesta: alSiesta,
  'En vivo en el Club': alEnVivo
}

export const wallArt: string[] = [
  plNoches, alCostaNorte, plFocus, alPostales, alAsfalto, plIndie, alVeranoEterno, alRevelado,
  plLiked, alKilometroCero, alLowTide, plRock, alGreenhouse, alLumen, plLofi, alWeather,
  alFiebre, alSemana, alCiudadDormida, alAvenida, alInterferencia, alAltoVoltaje, alVertigo, alApuntes
]
