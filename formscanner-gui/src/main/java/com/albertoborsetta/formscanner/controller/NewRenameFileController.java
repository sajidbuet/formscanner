package com.albertoborsetta.formscanner.controller;

import com.albertoborsetta.formscanner.commons.FormScannerConstants;
import com.albertoborsetta.formscanner.commons.FormScannerConstants.Action;
import com.albertoborsetta.formscanner.model.FormScannerModel;
import com.albertoborsetta.formscanner.gui.RenameFileFrame;
import java.awt.Component;

import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.FocusEvent;
import java.awt.event.FocusListener;
import java.awt.event.ItemEvent;
import java.awt.event.ItemListener;
import java.awt.event.KeyEvent;
import java.awt.event.KeyListener;
import java.util.ArrayList;
import java.util.List;
import javax.swing.DefaultComboBoxModel;
import javax.swing.JComboBox;

import javax.swing.JTextField;
import javax.swing.SwingUtilities;

public class NewRenameFileController implements ActionListener, FocusListener, ItemListener, KeyListener {

    private final FormScannerModel model;
    private RenameFileFrame view;

    public NewRenameFileController(FormScannerModel model) {
        this.model = model;
    }

    public void add(RenameFileFrame view) {
        this.view = view;
    }

    // ActionListener
    @Override
    public void actionPerformed(ActionEvent e) {
        Action act = Action.valueOf(e.getActionCommand());
        switch (act) {
            case RENAME_FILES_CURRENT:
                model.renameFiles(FormScannerConstants.RENAME_FILES_CURRENT);
                break;
            case RENAME_FILES_SKIP:
                model.renameFiles(FormScannerConstants.RENAME_FILES_SKIP);
                break;
            default:
                break;
        }
    }

    @Override
    public void focusGained(FocusEvent e) {
        ((JTextField) e.getComponent()).selectAll();

    }

    @Override
    public void focusLost(FocusEvent e) {
        view.setOkEnabled(true);
    }

    @Override
    public void itemStateChanged(ItemEvent arg0) {
        view.setOkEnabled(true);
        
    }

    @Override
    public void keyTyped(KeyEvent arg0) {
    }

    @Override
    public void keyPressed(KeyEvent e) {
        if ((e.getKeyCode() == KeyEvent.VK_ENTER) && (view.isOkEnabled())) {
            view.setOkEnabled(false);
            model.renameFiles(FormScannerConstants.RENAME_FILES_CURRENT);
        } else if ((e.getKeyCode() == KeyEvent.VK_ENTER) && (!view.isOkEnabled())) {
            model.renameFiles(FormScannerConstants.RENAME_FILES_SKIP);
        } else {
            view.setOkEnabled(true);
        }
    }

    @Override
    public void keyReleased(KeyEvent e) {
        Component c = e.getComponent();
        Component parent = c.getParent();
        
        if (c instanceof JTextField && parent instanceof JComboBox) {
            final JTextField textField = (JTextField) c;
            final JComboBox comboBox = (JComboBox) parent;
            final int keyCode = e.getKeyCode();
            SwingUtilities.invokeLater(new Runnable() {

                    @Override
                    public void run() {
                        if (!(keyCode == KeyEvent.VK_DOWN || keyCode == KeyEvent.VK_UP) ) {
                            comboFilter(comboBox, textField.getText());
                        }
                    }
            });
        }
    }
    
    public void comboFilter(JComboBox comboBox, String enteredText)
    {
        List<String> entriesFiltered = new ArrayList<String>();

        for (String entry : model.getResidentNames())
        {
            if (entry.toLowerCase().contains(enteredText.toLowerCase()))
            {
                entriesFiltered.add(entry);
            }
        }

        if (entriesFiltered.size() > 0)
        {
            comboBox.setModel(
                    new DefaultComboBoxModel(
                        entriesFiltered.toArray()));
            comboBox.setSelectedItem(enteredText);
            comboBox.showPopup();
        }
        else
        {
            comboBox.hidePopup();
        }
    }
    
}