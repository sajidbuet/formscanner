package com.albertoborsetta.formscanner.commons.resources;

import java.awt.Image;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.Scanner;

import javax.imageio.ImageIO;
import javax.swing.ImageIcon;

import org.apache.logging.log4j.Logger;
import org.apache.logging.log4j.LogManager;

public class FormScannerResources {

    private static final String PNG = ".png";
    private static final String TXT = ".txt";
    private static String iconsPath;
    private static String licensePath;
    private static String residentsPath;
    private static String template;
    private static final Logger logger = LogManager
            .getLogger(FormScannerResources.class.getName());

    public static void setResources(String path) {
        iconsPath = path + "/icons/";
        licensePath = path + "/license/";
        residentsPath = path + "/residents/";
    }

    public static ImageIcon getIconFor(String key) {
        ImageIcon icon = new ImageIcon(iconsPath + key + PNG);
        return icon;
    }

    public static void setTemplate(String tpl) {
        template = tpl;
    }

    public static File getTemplate() {
        return new File(template);
    }

    public static File getLicense() {
        return new File(licensePath + "license.txt");
    }

    public static Image getFormScannerIcon() {
        try {
            Image icon = ImageIO.read(new File(
                    iconsPath + FormScannerResourcesKeys.FORMSCANNER_ICON + PNG));
            return icon;
        } catch (IOException e) {
            logger.catching(e);
            return null;
        }
    }
    
    public static String getDefaultResidentsFilePath(){
        return residentsPath + FormScannerResourcesKeys.RESIDENTS_FILE_NAME +TXT;
    }

    public static String[] getResidentNames(String filePath) {

        try {
            Scanner scanner = new Scanner(new File(filePath));
            
            String line = scanner.nextLine();
            
            String names[] = line.split(";");
            
            for (int j = 0; j < names.length; j++) {
                names[j] = names[j].trim();
            }
            
            return names;
        } catch (FileNotFoundException ex) {
            logger.catching(ex);
            return null;
        }

    }

}
