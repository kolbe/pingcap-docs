CREATE DATABASE IF NOT EXISTS bikeshare;
DROP TABLE IF EXISTS bikeshare.trips;
CREATE TABLE bikeshare.trips (
  trip_id bigint(20) NOT NULL AUTO_INCREMENT,
  duration int(11) NOT NULL,
  start_date datetime DEFAULT NULL,
  end_date datetime DEFAULT NULL,
  start_station_number int(11) DEFAULT NULL,
  start_station varchar(255) DEFAULT NULL,
  end_station_number int(11) DEFAULT NULL,
  end_station varchar(255) DEFAULT NULL,
  bike_number varchar(255) DEFAULT NULL,
  member_type varchar(255) DEFAULT NULL,
  PRIMARY KEY (trip_id)
);
